import CryptoKit
import Foundation

actor LocalONVIFCameraService {
    static let shared = LocalONVIFCameraService()

    private struct SessionInfo {
        let mediaServiceURL: URL
        let ptzServiceURL: URL?
        let profileToken: String
    }

    private var sessionCache: [String: SessionInfo] = [:]

    func validateCredentials(for camera: CameraRecord) async throws {
        _ = try await authenticatedCapabilities(for: camera)
    }

    func sendPTZ(command: CameraCommand, camera: CameraRecord) async -> String {
        do {
            let session = try await sessionInfo(for: camera)
            guard let ptzServiceURL = session.ptzServiceURL else {
                return "PTZ Service not reported by this camera"
            }

            let velocity = Self.velocity(for: command)
            let body = """
            <tptz:ContinuousMove>
              <tptz:ProfileToken>\(session.profileToken)</tptz:ProfileToken>
              <tptz:Velocity>
                <tt:PanTilt x="\(velocity.pan)" y="\(velocity.tilt)"/>
                <tt:Zoom x="\(velocity.zoom)"/>
              </tptz:Velocity>
            </tptz:ContinuousMove>
            """

            _ = try await sendSOAPRequest(
                to: ptzServiceURL,
                action: "http://www.onvif.org/ver20/ptz/wsdl/ContinuousMove",
                body: body,
                camera: camera
            )

            try? await Task.sleep(nanoseconds: UInt64(command.durationMs + 120) * 1_000_000)

            let stopBody = """
            <tptz:Stop>
              <tptz:ProfileToken>\(session.profileToken)</tptz:ProfileToken>
              <tptz:PanTilt>true</tptz:PanTilt>
              <tptz:Zoom>true</tptz:Zoom>
            </tptz:Stop>
            """

            _ = try? await sendSOAPRequest(
                to: ptzServiceURL,
                action: "http://www.onvif.org/ver20/ptz/wsdl/Stop",
                body: stopBody,
                camera: camera
            )

            return "Local camera command sent."
        } catch {
            if Self.isUnsupportedPTZError(error) {
                return "PTZ Service not reported by this camera"
            }
            return error.localizedDescription
        }
    }

    private func sessionInfo(for camera: CameraRecord) async throws -> SessionInfo {
        let cacheKey = [camera.id.uuidString, camera.trimmedHost, String(camera.onvifPort), camera.sanitizedUsername].joined(separator: "|")
        if let cached = sessionCache[cacheKey] {
            return cached
        }

        guard let deviceServiceURL = camera.deviceServiceURL else {
            throw ONVIFError.invalidResponse("Invalid ONVIF device service URL.")
        }

        let capabilitiesData = try await authenticatedCapabilities(for: camera, deviceServiceURL: deviceServiceURL)

        guard let capabilitiesXML = String(data: capabilitiesData, encoding: .utf8) else {
            throw ONVIFError.invalidResponse("Unreadable capabilities response.")
        }

        let mediaServiceURL = Self.normalizeServiceURL(Self.extractServiceURL(named: "Media", in: capabilitiesXML), hostCamera: camera)
            ?? Self.fallbackServiceURL(path: "/onvif/media_service", camera: camera)
            ?? deviceServiceURL
        let ptzServiceURL = Self.normalizeServiceURL(Self.extractServiceURL(named: "PTZ", in: capabilitiesXML), hostCamera: camera)

        let profilesData = try await sendSOAPRequest(
            to: mediaServiceURL,
            action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles",
            body: "<trt:GetProfiles/>",
            camera: camera
        )

        guard
            let profilesXML = String(data: profilesData, encoding: .utf8),
            let profileToken = Self.extractFirstProfileToken(in: profilesXML)
        else {
            throw ONVIFError.invalidResponse("Unable to resolve media profile.")
        }

        let session = SessionInfo(mediaServiceURL: mediaServiceURL, ptzServiceURL: ptzServiceURL, profileToken: profileToken)
        sessionCache[cacheKey] = session
        return session
    }

    private func authenticatedCapabilities(for camera: CameraRecord, deviceServiceURL: URL? = nil) async throws -> Data {
        guard let url = deviceServiceURL ?? camera.deviceServiceURL else {
            throw ONVIFError.invalidResponse("Invalid ONVIF device service URL.")
        }
        do {
            return try await sendSOAPRequest(
                to: url,
                action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
                body: "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>",
                camera: camera,
                authMode: .wsse
            )
        } catch {
            return try await sendSOAPRequest(
                to: url,
                action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
                body: "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>",
                camera: camera,
                authMode: .basicAndWsse
            )
        }
    }

    private enum AuthMode {
        case wsse
        case basicAndWsse
    }

    private func sendSOAPRequest(to url: URL, action: String, body: String, camera: CameraRecord, authMode: AuthMode = .wsse) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = soapEnvelope(body: body, camera: camera).data(using: .utf8)
        if authMode == .basicAndWsse {
            let token = "\(camera.sanitizedUsername):\(camera.sanitizedPassword)"
                .data(using: .utf8)?
                .base64EncodedString() ?? ""
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ONVIFError.invalidResponse("No ONVIF HTTP response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown ONVIF error"
            throw ONVIFError.httpFailure(httpResponse.statusCode, message)
        }

        return data
    }

    private func soapEnvelope(body: String, camera: CameraRecord) -> String {
        let nonce = Self.randomNonce()
        let created = Self.createdTimestamp()
        let digest = Self.passwordDigest(nonce: nonce, created: created, password: camera.sanitizedPassword)
        let nonceString = nonce.base64EncodedString()

        return """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
                    xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
                    xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"
                    xmlns:tt="http://www.onvif.org/ver10/schema"
                    xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
                    xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
          <s:Header>
            <wsse:Security s:mustUnderstand="1">
              <wsse:UsernameToken>
                <wsse:Username>\(camera.sanitizedUsername)</wsse:Username>
                <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password>
                <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceString)</wsse:Nonce>
                <wsu:Created>\(created)</wsu:Created>
              </wsse:UsernameToken>
            </wsse:Security>
          </s:Header>
          <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
    }

    private static func randomNonce() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    private static func createdTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func passwordDigest(nonce: Data, created: String, password: String) -> String {
        var data = Data()
        data.append(nonce)
        data.append(Data(created.utf8))
        data.append(Data(password.utf8))
        let digest = Insecure.SHA1.hash(data: data)
        return Data(digest).base64EncodedString()
    }

    private static func extractTag(named tag: String, in xml: String) -> String? {
        let pattern = "<(?:[A-Za-z0-9_\\-]+:)?\(tag)>(.*?)</(?:[A-Za-z0-9_\\-]+:)?\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractServiceURL(named service: String, in xml: String) -> URL? {
        let pattern = "<(?:[A-Za-z0-9_\\-]+:)?\(service)\\b.*?</(?:[A-Za-z0-9_\\-]+:)?\(service)>"
        guard let blockRegex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let blockMatch = blockRegex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let blockRange = Range(blockMatch.range(at: 0), in: xml),
              let xaddr = extractTag(named: "XAddr", in: String(xml[blockRange])) else {
            return nil
        }
        return URL(string: xaddr)
    }

    private static func extractFirstProfileToken(in xml: String) -> String? {
        let pattern = "<(?:[A-Za-z0-9_\\-]+:)?Profiles\\b[^>]*token=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private static func normalizeServiceURL(_ serviceURL: URL?, hostCamera camera: CameraRecord) -> URL? {
        guard let serviceURL else { return nil }
        var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        components?.host = camera.trimmedHost
        components?.port = camera.onvifPort
        return components?.url ?? serviceURL
    }

    private static func fallbackServiceURL(path: String, camera: CameraRecord) -> URL? {
        URL(string: "http://\(camera.trimmedHost):\(camera.onvifPort)\(path)")
    }

    private static func velocity(for command: CameraCommand) -> (pan: Double, tilt: Double, zoom: Double) {
        switch command {
        case .up: (0, 0.4, 0)
        case .down: (0, -0.4, 0)
        case .left: (-0.4, 0, 0)
        case .right: (0.4, 0, 0)
        case .zoomIn: (0, 0, 0.4)
        case .zoomOut: (0, 0, -0.4)
        }
    }

    private static func isUnsupportedPTZError(_ error: Error) -> Bool {
        guard case ONVIFError.httpFailure(let statusCode, let message) = error else {
            return false
        }

        let lowercasedMessage = message.lowercased()
        return statusCode == 400
            || lowercasedMessage.contains("fault")
            || lowercasedMessage.contains("invalidargval")
            || lowercasedMessage.contains("ptz")
    }
}

enum ONVIFError: LocalizedError {
    case invalidResponse(String)
    case httpFailure(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): message
        case .httpFailure(let statusCode, let message): "ONVIF request failed (\(statusCode)): \(message)"
        }
    }
}
