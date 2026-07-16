import Foundation
import VLCKit

final class RTSPPlayerController: NSObject, ObservableObject {
    let player = VLCMediaPlayer()

    @Published private(set) var rtspURL: URL
    @Published var statusText = "Idle"
    @Published var errorMessage: String?

    init(rtspURL: URL) {
        self.rtspURL = rtspURL
        super.init()
        player.delegate = self
        configureMedia()
    }

    func play() {
        errorMessage = nil
        if player.media == nil {
            configureMedia()
        }
        statusText = "Connecting..."
        player.play()
    }

    func stop() {
        player.stop()
        statusText = "Stopped"
    }

    func setStream(url: URL) {
        guard rtspURL != url else { return }
        rtspURL = url
        reload()
    }

    func reload() {
        player.stop()
        configureMedia()
        play()
    }

    private func configureMedia() {
        let media = VLCMedia(url: rtspURL)
        media.addOptions([
            "network-caching": 150,
            "rtsp-tcp": true,
            "clock-jitter": 0,
            "clock-synchro": 0,
            "no-audio": true
        ])
        player.media = media
    }
}

extension RTSPPlayerController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ notification: Notification) {
        let nextStatus: String
        let nextErrorMessage: String?

        switch player.state {
        case .opening:
            nextStatus = "Opening stream..."
            nextErrorMessage = nil
        case .buffering:
            nextStatus = "Buffering..."
            nextErrorMessage = nil
        case .playing:
            nextStatus = "Playing"
            nextErrorMessage = nil
        case .paused:
            nextStatus = "Paused"
            nextErrorMessage = nil
        case .stopped:
            nextStatus = "Stopped"
            nextErrorMessage = nil
        case .ended:
            nextStatus = "Ended"
            nextErrorMessage = nil
        case .error:
            nextStatus = "Playback error"
            nextErrorMessage = "VLC could not play the RTSP stream. Verify the camera is reachable and credentials are correct."
        default:
            nextStatus = "Idle"
            nextErrorMessage = nil
        }

        DispatchQueue.main.async {
            self.statusText = nextStatus
            self.errorMessage = nextErrorMessage
        }
    }
}
