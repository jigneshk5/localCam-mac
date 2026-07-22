import AVFoundation
import AppKit
import SwiftUI

struct VLCVideoContainerView: NSViewRepresentable {
    let controller: RTSPPlayerController

    func makeNSView(context: Context) -> NativeRTSPVideoNSView {
        let view = NativeRTSPVideoNSView()
        controller.attach(displayLayer: view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: NativeRTSPVideoNSView, context: Context) {
        controller.attach(displayLayer: nsView.displayLayer)
    }

    static func dismantleNSView(_ nsView: NativeRTSPVideoNSView, coordinator: Void) {
        nsView.displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
    }
}

final class NativeRTSPVideoNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
