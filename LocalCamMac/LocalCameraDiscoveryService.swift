import Darwin
import Foundation
import Network

final class LocalCameraDiscoveryService {
    static let shared = LocalCameraDiscoveryService()

    private let multicastAddress = "239.255.255.250"
    private let multicastPort: UInt16 = 3702
    private let maxConcurrentSubnetProbes = 64

    private init() {}

    func isWiFiAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.localcam.macos.network-monitor")
            var didResume = false

            monitor.pathUpdateHandler = { path in
                guard !didResume else { return }
                didResume = true
                let hasNetwork = path.status == .satisfied
                continuation.resume(returning: hasNetwork)
                monitor.cancel()
            }

            queue.asyncAfter(deadline: .now() + 1.0) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: true)
                monitor.cancel()
            }

            monitor.start(queue: queue)
        }
    }

    func search(timeout: TimeInterval = 4.0) async -> [DiscoveredCamera] {
        let multicastResults = await discoverByMulticast(timeout: timeout)
        if !multicastResults.isEmpty {
            return multicastResults
        }
        return await discoverBySubnetScan()
    }

    private func discoverByMulticast(timeout: TimeInterval) async -> [DiscoveredCamera] {
        await Task.detached(priority: .userInitiated) { [multicastAddress, multicastPort] in
            var results: [String: DiscoveredCamera] = [:]
            let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard socketDescriptor >= 0 else { return [] }
            defer { close(socketDescriptor) }

            var yes: Int32 = 1
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var timeoutValue = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

            let probe = Self.discoveryProbe()
            probe.withCString { pointer in
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(multicastPort).bigEndian
                inet_pton(AF_INET, multicastAddress, &address.sin_addr)

                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        _ = sendto(socketDescriptor, pointer, strlen(pointer), 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var buffer = [UInt8](repeating: 0, count: 65535)
                var sender = sockaddr_storage()
                var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

                let count = withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        recvfrom(socketDescriptor, &buffer, buffer.count, 0, socketAddress, &senderLength)
                    }
                }

                guard count > 0 else { continue }
                let data = Data(buffer.prefix(count))
                guard let xml = String(data: data, encoding: .utf8),
                      let camera = Self.parseDiscoveryResponse(xml) else {
                    continue
                }
                results[camera.host] = camera
            }

            return Array(results.values).sorted { $0.host < $1.host }
        }.value
    }

    private func discoverBySubnetScan() async -> [DiscoveredCamera] {
        guard let localIP = Self.currentIPAddress(), let subnetPrefix = Self.classCSubnetPrefix(from: localIP) else {
            return []
        }

        let ports = [2020, 8800, 8000, 80, 8080, 8899, 8890, 5000]
        var candidates: [(host: String, port: Int)] = []
        for port in ports {
            for hostSuffix in 1...254 {
                let host = "\(subnetPrefix).\(hostSuffix)"
                guard host != localIP else { continue }
                candidates.append((host, port))
            }
        }

        var results: [String: DiscoveredCamera] = [:]
        var startIndex = 0
        while startIndex < candidates.count {
            let chunk = Array(candidates[startIndex..<min(startIndex + maxConcurrentSubnetProbes, candidates.count)])
            await withTaskGroup(of: DiscoveredCamera?.self) { group in
                for candidate in chunk {
                    group.addTask {
                        await Self.probeONVIFDevice(host: candidate.host, port: candidate.port)
                    }
                }
                for await camera in group {
                    guard let camera else { continue }
                    results[camera.host] = camera
                }
            }
            startIndex += maxConcurrentSubnetProbes
        }
        return Array(results.values).sorted { $0.host < $1.host }
    }
}

private extension LocalCameraDiscoveryService {
    static func discoveryProbe() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
                    xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
          <e:Header>
            <w:MessageID>uuid:\(UUID().uuidString)</w:MessageID>
            <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
            <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
          </e:Header>
          <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>
        </e:Envelope>
        """
    }

    static func parseDiscoveryResponse(_ xml: String) -> DiscoveredCamera? {
        guard let xaddrs = firstMatch(in: xml, pattern: #"<(?:\w+:)?XAddrs>(.*?)</(?:\w+:)?XAddrs>"#),
              let serviceURL = xaddrs.components(separatedBy: .whitespacesAndNewlines).first(where: { !$0.isEmpty }),
              let url = URL(string: serviceURL),
              let host = url.host else {
            return nil
        }

        let scopes = firstMatch(in: xml, pattern: #"<(?:\w+:)?Scopes[^>]*>(.*?)</(?:\w+:)?Scopes>"#) ?? ""
        let xAddrs = xaddrs.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return DiscoveredCamera(
            name: displayName(scopes: scopes, fallbackHost: host),
            host: host,
            rtspPort: 554,
            onvifPort: url.port ?? 8000,
            xAddrs: xAddrs
        )
    }

    static func probeONVIFDevice(host: String, port: Int) async -> DiscoveredCamera? {
        guard let url = URL(string: "http://\(host):\(port)/onvif/device_service") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.7
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = discoveryCapabilitiesProbe().data(using: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.7
        configuration.timeoutIntervalForResource = 0.7
        let session = URLSession(configuration: configuration)

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  [200, 401, 405].contains(httpResponse.statusCode) else {
                return nil
            }
            return DiscoveredCamera(
                name: "ONVIF Camera \(host)",
                host: host,
                rtspPort: 554,
                onvifPort: port,
                xAddrs: [url.absoluteString]
            )
        } catch {
            return nil
        }
    }

    static func discoveryCapabilitiesProbe() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body>
            <tds:GetCapabilities xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
              <tds:Category>All</tds:Category>
            </tds:GetCapabilities>
          </s:Body>
        </s:Envelope>
        """
    }

    static func currentIPAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while pointer != nil {
            defer { pointer = pointer?.pointee.ifa_next }
            guard let interface = pointer?.pointee,
                  let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard ["en0", "en1"].contains(name) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addressPointer, socklen_t(addressPointer.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            return String(cString: hostname)
        }
        return nil
    }

    static func classCSubnetPrefix(from ipAddress: String) -> String? {
        let parts = ipAddress.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayName(scopes: String, fallbackHost: String) -> String {
        if let name = scopes
            .components(separatedBy: .whitespacesAndNewlines)
            .first(where: { $0.lowercased().contains("name/") })?
            .components(separatedBy: "name/")
            .last?
            .removingPercentEncoding,
           !name.isEmpty {
            return name.replacingOccurrences(of: "_", with: " ")
        }
        return "ONVIF Camera \(fallbackHost)"
    }
}
