import Foundation

enum CameraType: String, Codable, CaseIterable, Identifiable {
    case hikvision
    case dahua
    case bosch
    case axis
    case reolink
    case tpLink
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hikvision: "Hikvision"
        case .dahua: "Dahua"
        case .bosch: "Bosch"
        case .axis: "Axis"
        case .reolink: "Reolink"
        case .tpLink: "TP-Link"
        case .other: "Other"
        }
    }

    var defaultRTSPPort: Int { 554 }

    var defaultONVIFPort: Int {
        switch self {
        case .hikvision, .dahua, .bosch, .axis: 80
        case .tpLink: 2020
        case .reolink: 8000
        case .other: 8080
        }
    }

    var defaultUsername: String { "admin" }

    func rtspPath(for streamType: StreamType) -> String {
        switch self {
        case .hikvision:
            streamType == .main ? "Streaming/Channels/101/" : "Streaming/Channels/102/"
        case .dahua:
            streamType == .main ? "cam/realmonitor?channel=1&subtype=0" : "cam/realmonitor?channel=1&subtype=1"
        case .bosch:
            streamType == .main ? "" : "?inst=2"
        case .axis:
            streamType == .main ? "axis-media/media.amp" : "axis-media/media.amp?resolution=640x480"
        case .reolink:
            streamType == .main ? "h264Preview_01_main" : "h264Preview_01_sub"
        case .tpLink:
            streamType == .main ? "stream1" : "stream2"
        case .other:
            streamType == .main ? "11" : "12"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .hikvision: "LogoHikvision"
        case .dahua: "LogoDahua"
        case .bosch: "LogoBosch"
        case .axis: "LogoAxis"
        case .reolink: "LogoReolink"
        case .tpLink: "LogoTPLink"
        case .other: nil
        }
    }

    var subtitle: String {
        "RTSP \(defaultRTSPPort), ONVIF \(defaultONVIFPort), username \(defaultUsername)"
    }
}

enum StreamType: String, Codable, CaseIterable, Identifiable {
    case main
    case sub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: "Main Stream"
        case .sub: "Sub Stream"
        }
    }
}

enum CameraCommand: String, CaseIterable, Identifiable {
    case up
    case down
    case left
    case right
    case zoomIn
    case zoomOut

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .zoomIn: "plus"
        case .zoomOut: "minus"
        }
    }

    var durationMs: Int { 180 }
}

struct CameraRecord: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var cameraType: CameraType
    var host: String
    var username: String
    var password: String
    var rtspPort: Int
    var onvifPort: Int
    var rtspPath: String
    var rtspSubPath: String

    init(
        id: UUID = UUID(),
        name: String,
        cameraType: CameraType,
        host: String,
        username: String = "admin",
        password: String = "",
        rtspPort: Int? = nil,
        onvifPort: Int? = nil,
        rtspPath: String? = nil,
        rtspSubPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cameraType = cameraType
        self.host = host
        self.username = username
        self.password = password
        self.rtspPort = rtspPort ?? cameraType.defaultRTSPPort
        self.onvifPort = onvifPort ?? cameraType.defaultONVIFPort
        self.rtspPath = rtspPath ?? cameraType.rtspPath(for: .main)
        self.rtspSubPath = rtspSubPath ?? cameraType.rtspPath(for: .sub)
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var sanitizedUsername: String {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "admin" : value
    }

    var sanitizedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var deviceServiceURL: URL? {
        URL(string: "http://\(trimmedHost):\(onvifPort)/onvif/device_service")
    }

    func rtspPath(for stream: StreamType) -> String {
        if cameraType == .other {
            return stream == .main ? rtspPath : rtspSubPath
        }
        return cameraType.rtspPath(for: stream)
    }

    func manualRTSPURL(for streamType: StreamType) -> URL? {
        guard !trimmedHost.isEmpty else { return nil }
        let selectedPath = rtspPath(for: streamType)
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = trimmedHost
        components.port = rtspPort
        components.user = sanitizedUsername
        if !sanitizedPassword.isEmpty {
            components.password = sanitizedPassword
        }
        if let queryIndex = selectedPath.firstIndex(of: "?") {
            let path = String(selectedPath[..<queryIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = path.isEmpty ? "/" : "/\(path)"
            components.percentEncodedQuery = String(selectedPath[selectedPath.index(after: queryIndex)...])
        } else {
            let path = selectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = path.isEmpty ? "/" : "/\(path)"
        }
        return components.url
    }

    var connectionSummary: String {
        "\(trimmedHost)  •  RTSP \(rtspPort)  •  ONVIF \(onvifPort)"
    }
}

struct DiscoveredCamera: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var rtspPort: Int
    var onvifPort: Int
    var xAddrs: [String]
}
