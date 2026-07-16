import AppKit

@MainActor
enum ScreenshotCaptureService {
    enum CaptureError: LocalizedError {
        case missingWindow
        case unableToCreateBitmap
        case unableToEncodePNG

        var errorDescription: String? {
            switch self {
            case .missingWindow:
                "No visible Local Cam window was found."
            case .unableToCreateBitmap:
                "Unable to render the current window."
            case .unableToEncodePNG:
                "Unable to create the screenshot PNG."
            }
        }
    }

    static func captureActiveWindow() throws -> URL {
        guard let window = targetWindow else {
            throw CaptureError.missingWindow
        }

        guard let capture = captureCompositedScreenImage(for: window) else {
            throw CaptureError.unableToCreateBitmap
        }

        let targetSize = NSSize(width: 2560, height: 1600)
        guard let targetRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CaptureError.unableToCreateBitmap
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: targetRep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: targetSize).fill()
        NSImage(cgImage: capture.image, size: capture.size).draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: capture.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = targetRep.representation(using: .png, properties: [:]) else {
            throw CaptureError.unableToEncodePNG
        }

        let outputURL = try outputFileURL()
        try pngData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static var targetWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           keyWindow.isVisible,
           !keyWindow.isMiniaturized {
            return rootWindow(for: keyWindow)
        }

        if let mainWindow = NSApp.mainWindow,
           mainWindow.isVisible,
           !mainWindow.isMiniaturized {
            return rootWindow(for: mainWindow)
        }

        return NSApp.windows.first { window in
            window.isVisible
                && !window.isMiniaturized
                && window.contentView != nil
                && window.sheetParent == nil
        }
    }

    private static func rootWindow(for window: NSWindow) -> NSWindow {
        var root = window
        while let parent = root.sheetParent {
            root = parent
        }
        return root
    }

    private static func captureCompositedScreenImage(for window: NSWindow) -> CaptureResult? {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return nil }

        let captureRect = quartzScreenRect(from: frame)
        guard let image = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        return CaptureResult(image: image, size: frame.size)
    }

    private static func quartzScreenRect(from appKitRect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) }) ?? NSScreen.main else {
            return appKitRect
        }

        return CGRect(
            x: appKitRect.minX,
            y: screen.frame.maxY - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    private static func outputFileURL() throws -> URL {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let folderURL = desktopURL.appendingPathComponent("Local Cam Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let fileName = "Local-Cam-\(formatter.string(from: Date())).png"
        return folderURL.appendingPathComponent(fileName)
    }

    private struct CaptureResult {
        let image: CGImage
        let size: NSSize
    }
}
