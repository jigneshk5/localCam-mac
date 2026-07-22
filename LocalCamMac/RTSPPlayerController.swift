import AVFoundation
import AppKit
import Foundation
import OSLog

final class RTSPPlayerController: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: "rtsptest.geekpoint.local", category: "RTSP")
    @Published private(set) var rtspURL: URL
    @Published var statusText = "Idle"
    @Published var errorMessage: String?

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var client: NativeRTSPClient?
    private var isPlaying = false
    private var hasDisplayedFrame = false
    private var activationObserver: NSObjectProtocol?

    init(rtspURL: URL) {
        self.rtspURL = rtspURL
        super.init()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.errorMessage?.hasPrefix("Local network access is denied") == true,
                  !self.isPlaying else { return }
            self.play()
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        client?.stop()
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    func detach(displayLayer: AVSampleBufferDisplayLayer) {
        if self.displayLayer === displayLayer {
            self.displayLayer = nil
        }
    }

    func play() {
        guard !isPlaying else { return }
        errorMessage = nil
        hasDisplayedFrame = false
        statusText = "Connecting..."
        displayLayer?.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )

        let client = NativeRTSPClient(url: rtspURL)
        client.delegate = self
        self.client = client
        isPlaying = true
        print("[LocalCam][NativeRTSP] play \(redactedURLString(rtspURL))")
        NSLog("[LocalCam][NativeRTSP] starting playback")
#if DEBUG
        UserDefaults.standard.set("starting", forKey: "local-cam.debug.rtsp-status")
#endif
        Self.logger.info("Starting native RTSP playback")
        client.start()
    }

    func stop() {
        isPlaying = false
        client?.stop()
        client = nil
        displayLayer?.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        statusText = "Stopped"
    }

    func setStream(url: URL) {
        guard rtspURL != url else { return }
        rtspURL = url
        reload()
    }

    func reload() {
        stop()
        play()
    }

    private func redactedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "rtsp://<invalid>"
        }
        if components.password != nil {
            components.password = "*****"
        }
        return components.string ?? "rtsp://<invalid>"
    }
}

extension RTSPPlayerController: NativeRTSPClientDelegate {
    func rtspClient(_ client: NativeRTSPClient, didChangeStatus status: String) {
        guard self.client === client, isPlaying else { return }
        statusText = status
        errorMessage = nil
        print("[LocalCam][NativeRTSP] status=\(status)")
        NSLog("[LocalCam][NativeRTSP] status=%@", status)
#if DEBUG
        UserDefaults.standard.set(status, forKey: "local-cam.debug.rtsp-status")
#endif
        Self.logger.info("RTSP status: \(status, privacy: .public)")
    }

    func rtspClient(_ client: NativeRTSPClient, didProduce sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [weak self, weak client] in
            guard let self, let client, self.client === client, self.isPlaying,
                  let displayLayer = self.displayLayer else { return }

            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                print("[LocalCam][NativeRTSP] display layer failed: \(renderer.error?.localizedDescription ?? "unknown")")
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            guard renderer.isReadyForMoreMediaData else { return }
            renderer.enqueue(sampleBuffer)
            if !self.hasDisplayedFrame {
                self.hasDisplayedFrame = true
                self.statusText = "Playing"
                self.errorMessage = nil
                print("[LocalCam][NativeRTSP] first video frame displayed")
                NSLog("[LocalCam][NativeRTSP] first H.264 frame enqueued")
#if DEBUG
                UserDefaults.standard.set("first-frame", forKey: "local-cam.debug.rtsp-status")
#endif
                Self.logger.info("First H.264 video frame enqueued")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [displayLayer] in
                    let renderer = displayLayer.sampleBufferRenderer
                    if renderer.status == .failed {
                        let message = renderer.error?.localizedDescription ?? "unknown display error"
                        NSLog("[LocalCam][NativeRTSP] display verification failed=%@", message)
#if DEBUG
                        UserDefaults.standard.set("display-error: \(message)", forKey: "local-cam.debug.rtsp-status")
#endif
                    } else if displayLayer.isReadyForDisplay {
                        NSLog("[LocalCam][NativeRTSP] display layer accepted H.264 video")
#if DEBUG
                        UserDefaults.standard.set("playing", forKey: "local-cam.debug.rtsp-status")
#endif
                    } else {
                        NSLog("[LocalCam][NativeRTSP] display layer is still preparing video")
                    }
                }
            }
        }
    }

    func rtspClient(_ client: NativeRTSPClient, didFail message: String) {
        guard self.client === client, isPlaying else { return }
        isPlaying = false
        self.client = nil
        statusText = "Playback error"
        errorMessage = message
        print("[LocalCam][NativeRTSP] error=\(message)")
        NSLog("[LocalCam][NativeRTSP] error=%@", message)
#if DEBUG
        UserDefaults.standard.set("error: \(message)", forKey: "local-cam.debug.rtsp-status")
#endif
        Self.logger.error("RTSP error: \(message, privacy: .public)")
    }
}
