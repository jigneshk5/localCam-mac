import AppKit
import SwiftUI
import VLCKit

struct VLCVideoContainerView: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.drawable = view
        player.videoAspectRatio = nil
        player.scaleFactor = 0
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let currentDrawable = player.drawable as AnyObject?
        if currentDrawable !== nsView {
            player.drawable = nsView
        }
        player.videoAspectRatio = nil
        player.scaleFactor = 0
    }
}
