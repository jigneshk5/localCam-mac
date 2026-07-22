import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation

protocol NativeRTSPClientDelegate: AnyObject {
    func rtspClient(_ client: NativeRTSPClient, didChangeStatus status: String)
    func rtspClient(_ client: NativeRTSPClient, didProduce sampleBuffer: CMSampleBuffer)
    func rtspClient(_ client: NativeRTSPClient, didFail message: String)
}

final class NativeRTSPClient {
    weak var delegate: NativeRTSPClientDelegate?

    private let sourceURL: URL
    private let workerQueue = DispatchQueue(label: "app.localcam.rtsp-client", qos: .userInitiated)
    private let stateLock = NSLock()

    private var socketDescriptor: Int32 = -1
    private var isStopped = false
    private var receiveBuffer = Data()
    private var sequenceNumber = 1
    private var sessionID: String?
    private var authentication: RTSPAuthentication?
    private var lastKeepAlive = Date()
    private let depacketizer = H264RTPDepacketizer()

    init(url: URL) {
        sourceURL = url
    }

    func start() {
        workerQueue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        stateLock.lock()
        isStopped = true
        let descriptor = socketDescriptor
        socketDescriptor = -1
        stateLock.unlock()

        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func run() {
        do {
            notifyStatus("Connecting...")
            let descriptor = try connectSocket()

            stateLock.lock()
            if isStopped {
                stateLock.unlock()
                Darwin.close(descriptor)
                return
            }
            socketDescriptor = descriptor
            stateLock.unlock()

            try negotiateSession()
            guard !stopped else { return }
            notifyStatus("Buffering...")
            try receiveInterleavedStream()
        } catch {
            guard !stopped else { return }
            let message = (error as? RTSPClientError)?.message ?? error.localizedDescription
            notifyFailure(message)
        }

        stop()
    }

    private var stopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStopped
    }

    private func connectSocket() throws -> Int32 {
        guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw RTSPClientError("The RTSP URL is invalid.")
        }
        let port = components.port ?? 554

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let lookupResult = getaddrinfo(host, String(port), &hints, &result)
        guard lookupResult == 0, let firstResult = result else {
            throw RTSPClientError("Could not resolve the camera host.")
        }
        defer { freeaddrinfo(firstResult) }

        var lastConnectError: Int32 = 0
        var candidate: UnsafeMutablePointer<addrinfo>? = firstResult
        while let address = candidate {
            let descriptor = Darwin.socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if descriptor >= 0 {
                var noSignal: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                if Darwin.connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                    return descriptor
                }
                lastConnectError = errno
                NSLog(
                    "[LocalCam][NativeRTSP] socket connect failed errno=%d (%s)",
                    lastConnectError,
                    strerror(lastConnectError)
                )
                Darwin.close(descriptor)
            }
            candidate = address.pointee.ai_next
        }

        if lastConnectError == EPERM || lastConnectError == EACCES ||
            (lastConnectError == ENETUNREACH && Self.isPrivateNetworkHost(host)) {
            throw RTSPClientError(
                "Local network access is denied. Allow Local Cam in System Settings > Privacy & Security > Local Network."
            )
        }
        let reason = lastConnectError == 0
            ? "unknown socket error"
            : String(cString: strerror(lastConnectError))
        throw RTSPClientError("Could not connect to RTSP port \(port): \(reason).")
    }

    private static func isPrivateNetworkHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)
    }

    private func negotiateSession() throws {
        let baseURI = try requestURI(from: sourceURL)

        var describeResponse = try sendRequest(
            method: "DESCRIBE",
            uri: baseURI,
            headers: ["Accept": "application/sdp"],
            includeAuthentication: false
        )

        if describeResponse.statusCode == 401 {
            guard let challenge = describeResponse.headers["www-authenticate"],
                  let parsedAuthentication = RTSPAuthentication(
                    challenge: challenge,
                    username: decodedUser,
                    password: decodedPassword
                  ) else {
                throw RTSPClientError("The camera requires unsupported RTSP authentication.")
            }
            authentication = parsedAuthentication
            describeResponse = try sendRequest(
                method: "DESCRIBE",
                uri: baseURI,
                headers: ["Accept": "application/sdp"]
            )
        }

        guard describeResponse.statusCode == 200 else {
            if describeResponse.statusCode == 401 {
                throw RTSPClientError("RTSP username or password is incorrect.")
            }
            throw RTSPClientError("Camera rejected RTSP DESCRIBE (\(describeResponse.statusCode)).")
        }

        guard let sdp = String(data: describeResponse.body, encoding: .utf8) else {
            throw RTSPClientError("Camera returned an invalid RTSP description.")
        }
        let sessionDescription = try SDPVideoDescription.parse(sdp)
        depacketizer.configure(
            sps: sessionDescription.sps,
            pps: sessionDescription.pps
        )

        let contentBase = describeResponse.headers["content-base"] ?? baseURI
        let trackURI = resolveControlURI(sessionDescription.control, contentBase: contentBase, fallbackBase: baseURI)
        let setupResponse = try sendRequest(
            method: "SETUP",
            uri: trackURI,
            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
        )
        guard setupResponse.statusCode == 200 else {
            throw RTSPClientError("Camera rejected RTSP-over-TCP SETUP (\(setupResponse.statusCode)).")
        }
        guard let sessionHeader = setupResponse.headers["session"] else {
            throw RTSPClientError("Camera did not return an RTSP session.")
        }
        sessionID = sessionHeader.split(separator: ";", maxSplits: 1).first.map(String.init)

        let playURI = contentBase.hasSuffix("/") ? contentBase : contentBase + "/"
        let playResponse = try sendRequest(
            method: "PLAY",
            uri: playURI,
            headers: ["Range": "npt=0.000-"]
        )
        guard playResponse.statusCode == 200 else {
            throw RTSPClientError("Camera rejected RTSP PLAY (\(playResponse.statusCode)).")
        }
    }

    private func sendRequest(
        method: String,
        uri: String,
        headers: [String: String] = [:],
        includeAuthentication: Bool = true
    ) throws -> RTSPResponse {
        var requestHeaders = headers
        requestHeaders["CSeq"] = String(sequenceNumber)
        requestHeaders["User-Agent"] = "Local Cam/1.2"
        sequenceNumber += 1

        if let sessionID {
            requestHeaders["Session"] = sessionID
        }
        if includeAuthentication, var authentication {
            requestHeaders["Authorization"] = authentication.authorizationHeader(method: method, uri: uri)
            self.authentication = authentication
        }

        var request = "\(method) \(uri) RTSP/1.0\r\n"
        for key in requestHeaders.keys.sorted() {
            request += "\(key): \(requestHeaders[key] ?? "")\r\n"
        }
        request += "\r\n"
        try write(Data(request.utf8))
        return try readRTSPResponse(timeout: 8)
    }

    private func write(_ data: Data) throws {
        let descriptor = currentDescriptor
        guard descriptor >= 0 else { throw RTSPClientError("RTSP connection is closed.") }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let sent = Darwin.send(descriptor, pointer, remaining, 0)
                if sent <= 0 {
                    throw RTSPClientError("Could not send the RTSP request.")
                }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
        }
    }

    private var currentDescriptor: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return socketDescriptor
    }

    private func readRTSPResponse(timeout: TimeInterval) throws -> RTSPResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !stopped {
            if let response = extractRTSPResponse() {
                return response
            }
            try receiveMoreData()
        }
        throw RTSPClientError("The camera timed out during RTSP setup.")
    }

    private func receiveMoreData() throws {
        let descriptor = currentDescriptor
        guard descriptor >= 0 else { throw RTSPClientError("RTSP connection is closed.") }

        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if received > 0 {
            receiveBuffer.append(contentsOf: bytes.prefix(received))
            return
        }
        if received == 0 {
            throw RTSPClientError("Camera closed the RTSP connection.")
        }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return
        }
        throw RTSPClientError("RTSP socket read failed (\(errno)).")
    }

    private func extractRTSPResponse() -> RTSPResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = receiveBuffer.range(of: separator) else { return nil }
        let headerData = receiveBuffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let responseEnd = bodyStart + contentLength
        guard receiveBuffer.count >= responseEnd else { return nil }

        let body = receiveBuffer.subdata(in: bodyStart..<responseEnd)
        receiveBuffer.removeSubrange(0..<responseEnd)
        return RTSPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private func receiveInterleavedStream() throws {
        while !stopped {
            try receiveMoreData()
            processStreamingBuffer()

            if Date().timeIntervalSince(lastKeepAlive) >= 20 {
                lastKeepAlive = Date()
                try sendKeepAlive()
            }
        }
    }

    private func processStreamingBuffer() {
        while !receiveBuffer.isEmpty {
            if receiveBuffer[0] == 0x24 {
                guard receiveBuffer.count >= 4 else { return }
                let channel = receiveBuffer[1]
                let payloadLength = Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
                guard receiveBuffer.count >= payloadLength + 4 else { return }
                let payload = receiveBuffer.subdata(in: 4..<(payloadLength + 4))
                receiveBuffer.removeSubrange(0..<(payloadLength + 4))
                if channel == 0, let sampleBuffer = depacketizer.consume(rtpPacket: payload) {
                    delegate?.rtspClient(self, didProduce: sampleBuffer)
                }
                continue
            }

            if receiveBuffer.starts(with: Data("RTSP/".utf8)) {
                guard extractRTSPResponse() != nil else { return }
                continue
            }

            let dollarIndex = receiveBuffer.firstIndex(of: 0x24)
            let rtspIndex = receiveBuffer.range(of: Data("RTSP/".utf8))?.lowerBound
            let nextIndex = [dollarIndex, rtspIndex].compactMap { $0 }.min()
            guard let nextIndex else {
                receiveBuffer.removeAll(keepingCapacity: true)
                return
            }
            receiveBuffer.removeSubrange(0..<nextIndex)
        }
    }

    private func sendKeepAlive() throws {
        let uri = try requestURI(from: sourceURL)
        var headers: [String: String] = [
            "CSeq": String(sequenceNumber),
            "User-Agent": "Local Cam/1.2"
        ]
        sequenceNumber += 1
        if let sessionID {
            headers["Session"] = sessionID
        }
        if var authentication {
            headers["Authorization"] = authentication.authorizationHeader(method: "GET_PARAMETER", uri: uri)
            self.authentication = authentication
        }

        var request = "GET_PARAMETER \(uri) RTSP/1.0\r\n"
        for key in headers.keys.sorted() {
            request += "\(key): \(headers[key] ?? "")\r\n"
        }
        request += "\r\n"
        try write(Data(request.utf8))
    }

    private var decodedUser: String {
        let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        return components?.user?.removingPercentEncoding ?? components?.user ?? ""
    }

    private var decodedPassword: String {
        let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        return components?.password?.removingPercentEncoding ?? components?.password ?? ""
    }

    private func requestURI(from url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RTSPClientError("The RTSP URL is invalid.")
        }
        components.user = nil
        components.password = nil
        guard let uri = components.string else {
            throw RTSPClientError("The RTSP URL is invalid.")
        }
        return uri
    }

    private func resolveControlURI(_ control: String, contentBase: String, fallbackBase: String) -> String {
        if control.lowercased().hasPrefix("rtsp://") {
            return control
        }
        let base = contentBase.isEmpty ? fallbackBase : contentBase
        if control.hasPrefix("/"), let url = URL(string: base), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.path = control
            components.query = nil
            return components.string ?? base + control
        }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    private func notifyStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.rtspClient(self, didChangeStatus: status)
        }
    }

    private func notifyFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.rtspClient(self, didFail: message)
        }
    }
}

private struct RTSPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private struct RTSPClientError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct SDPVideoDescription {
    let control: String
    let sps: Data?
    let pps: Data?

    static func parse(_ sdp: String) throws -> SDPVideoDescription {
        var isVideoSection = false
        var control: String?
        var sps: Data?
        var pps: Data?

        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                isVideoSection = line.hasPrefix("m=video")
                continue
            }
            guard isVideoSection else { continue }
            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
            }
            if line.hasPrefix("a=fmtp:"), let range = line.range(of: "sprop-parameter-sets=") {
                let value = line[range.upperBound...]
                    .split(separator: ";", maxSplits: 1)
                    .first
                    .map(String.init) ?? ""
                let parameterSets = value.split(separator: ",", maxSplits: 1).map(String.init)
                if parameterSets.count == 2 {
                    sps = Data(base64Encoded: parameterSets[0])
                    pps = Data(base64Encoded: parameterSets[1])
                }
            }
        }

        guard let control, !control.isEmpty else {
            throw RTSPClientError("No H.264 video track was found in the RTSP stream.")
        }
        return SDPVideoDescription(control: control, sps: sps, pps: pps)
    }
}

private enum RTSPAuthentication {
    case basic(username: String, password: String)
    case digest(DigestAuthentication)

    init?(challenge: String, username: String, password: String) {
        if challenge.lowercased().hasPrefix("basic") {
            self = .basic(username: username, password: password)
            return
        }
        if challenge.lowercased().hasPrefix("digest"), let digest = DigestAuthentication(challenge: challenge, username: username, password: password) {
            self = .digest(digest)
            return
        }
        return nil
    }

    mutating func authorizationHeader(method: String, uri: String) -> String {
        switch self {
        case let .basic(username, password):
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return "Basic \(token)"
        case var .digest(authentication):
            let value = authentication.authorizationHeader(method: method, uri: uri)
            self = .digest(authentication)
            return value
        }
    }
}

private struct DigestAuthentication {
    let username: String
    let password: String
    let realm: String
    let nonce: String
    let opaque: String?
    let qop: String?
    private(set) var nonceCount = 0

    init?(challenge: String, username: String, password: String) {
        let values = Self.challengeValues(challenge)
        guard let realm = values["realm"], let nonce = values["nonce"] else { return nil }
        self.username = username
        self.password = password
        self.realm = realm
        self.nonce = nonce
        opaque = values["opaque"]
        qop = values["qop"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0 == "auth" })
    }

    mutating func authorizationHeader(method: String, uri: String) -> String {
        nonceCount += 1
        let ha1 = Self.md5("\(username):\(realm):\(password)")
        let ha2 = Self.md5("\(method):\(uri)")
        var fields = [
            "username=\"\(username)\"",
            "realm=\"\(realm)\"",
            "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\""
        ]

        let response: String
        if let qop {
            let nonceCountText = String(format: "%08x", nonceCount)
            let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            response = Self.md5("\(ha1):\(nonce):\(nonceCountText):\(cnonce):\(qop):\(ha2)")
            fields.append("qop=\(qop)")
            fields.append("nc=\(nonceCountText)")
            fields.append("cnonce=\"\(cnonce)\"")
        } else {
            response = Self.md5("\(ha1):\(nonce):\(ha2)")
        }

        fields.append("response=\"\(response)\"")
        if let opaque {
            fields.append("opaque=\"\(opaque)\"")
        }
        return "Digest " + fields.joined(separator: ", ")
    }

    private static func challengeValues(_ challenge: String) -> [String: String] {
        let text = challenge.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        var current = ""
        var insideQuotes = false
        for character in text {
            if character == "\"" {
                insideQuotes.toggle()
                current.append(character)
            } else if character == ",", !insideQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }

        var values: [String: String] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class H264RTPDepacketizer {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var currentTimestamp: UInt32?
    private var accessUnit: [Data] = []
    private var fragmentedNAL: Data?
    private var waitingForKeyframe = true
    private var firstRTPTimestamp: UInt32?
    private var firstPresentationTime: CMTime?

    func configure(sps: Data?, pps: Data?) {
        if let sps { self.sps = sps }
        if let pps { self.pps = pps }
        formatDescription = nil
    }

    func consume(rtpPacket packet: Data) -> CMSampleBuffer? {
        guard packet.count >= 12, packet[0] >> 6 == 2 else { return nil }
        let csrcCount = Int(packet[0] & 0x0f)
        let hasExtension = packet[0] & 0x10 != 0
        let hasPadding = packet[0] & 0x20 != 0
        let marker = packet[1] & 0x80 != 0
        let timestamp = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7])

        var payloadOffset = 12 + csrcCount * 4
        guard payloadOffset <= packet.count else { return nil }
        if hasExtension {
            guard payloadOffset + 4 <= packet.count else { return nil }
            let extensionWords = Int(packet[payloadOffset + 2]) << 8 | Int(packet[payloadOffset + 3])
            payloadOffset += 4 + extensionWords * 4
        }
        var payloadEnd = packet.count
        if hasPadding, let padding = packet.last {
            payloadEnd -= Int(padding)
        }
        guard payloadOffset < payloadEnd else { return nil }

        var completedSample: CMSampleBuffer?
        if let currentTimestamp, currentTimestamp != timestamp, !accessUnit.isEmpty {
            completedSample = makeSampleBuffer()
            accessUnit.removeAll(keepingCapacity: true)
            fragmentedNAL = nil
        }
        currentTimestamp = timestamp

        let payload = packet.subdata(in: payloadOffset..<payloadEnd)
        appendPayload(payload)
        if marker {
            let markerSample = makeSampleBuffer()
            accessUnit.removeAll(keepingCapacity: true)
            fragmentedNAL = nil
            return markerSample ?? completedSample
        }
        return completedSample
    }

    private func appendPayload(_ payload: Data) {
        guard let firstByte = payload.first else { return }
        let nalType = firstByte & 0x1f

        switch nalType {
        case 1...23:
            appendNAL(payload)
        case 24:
            var offset = 1
            while offset + 2 <= payload.count {
                let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard length > 0, offset + length <= payload.count else { break }
                appendNAL(payload.subdata(in: offset..<(offset + length)))
                offset += length
            }
        case 28:
            guard payload.count >= 2 else { return }
            let fuIndicator = payload[0]
            let fuHeader = payload[1]
            let isStart = fuHeader & 0x80 != 0
            let isEnd = fuHeader & 0x40 != 0
            let reconstructedHeader = (fuIndicator & 0xe0) | (fuHeader & 0x1f)
            if isStart {
                fragmentedNAL = Data([reconstructedHeader])
                fragmentedNAL?.append(payload.dropFirst(2))
            } else {
                fragmentedNAL?.append(payload.dropFirst(2))
            }
            if isEnd, let nal = fragmentedNAL {
                appendNAL(nal)
                fragmentedNAL = nil
            }
        default:
            break
        }
    }

    private func appendNAL(_ nal: Data) {
        guard let firstByte = nal.first else { return }
        switch firstByte & 0x1f {
        case 7:
            if sps != nal {
                sps = nal
                formatDescription = nil
            }
        case 8:
            if pps != nal {
                pps = nal
                formatDescription = nil
            }
        default:
            accessUnit.append(nal)
        }
    }

    private func makeSampleBuffer() -> CMSampleBuffer? {
        guard !accessUnit.isEmpty else { return nil }
        let containsKeyframe = accessUnit.contains { ($0.first ?? 0) & 0x1f == 5 }
        if waitingForKeyframe, !containsKeyframe { return nil }
        if containsKeyframe { waitingForKeyframe = false }

        guard let formatDescription = currentFormatDescription() else { return nil }
        var sampleData = Data()
        for nal in accessUnit {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
            sampleData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = sampleData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        guard let currentTimestamp else { return nil }
        if firstRTPTimestamp == nil {
            firstRTPTimestamp = currentTimestamp
            let startupLead = CMTime(value: 9_000, timescale: 90_000)
            firstPresentationTime = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), startupLead)
        }
        guard let firstRTPTimestamp, let firstPresentationTime else { return nil }
        let timestampDelta = currentTimestamp &- firstRTPTimestamp
        let presentationTime = CMTimeAdd(
            firstPresentationTime,
            CMTime(value: Int64(timestampDelta), timescale: 90_000)
        )
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }
        if !containsKeyframe {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        return sampleBuffer
    }

    private func currentFormatDescription() -> CMVideoFormatDescription? {
        if let formatDescription { return formatDescription }
        guard let sps, let pps else { return nil }

        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsAddress = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsAddress = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-1)
                }
                var pointers: [UnsafePointer<UInt8>] = [spsAddress, ppsAddress]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return nil }
        formatDescription = description
        return description
    }
}
