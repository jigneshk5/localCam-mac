import SwiftUI

@main
struct LocalCamMacApp: App {
    @StateObject private var store = CameraStore()
    @State private var screenshotMessage: ScreenshotMessage?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 760)
                .alert(item: $screenshotMessage) { message in
                    Alert(
                        title: Text(message.title),
                        message: Text(message.detail),
                        dismissButton: .default(Text("OK"))
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Capture Screenshot") {
                    captureScreenshot()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    private func captureScreenshot() {
        do {
            let url = try ScreenshotCaptureService.captureActiveWindow()
            screenshotMessage = ScreenshotMessage(
                title: "Screenshot Saved",
                detail: url.path
            )
        } catch {
            screenshotMessage = ScreenshotMessage(
                title: "Screenshot Failed",
                detail: error.localizedDescription
            )
        }
    }
}

private struct ScreenshotMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
