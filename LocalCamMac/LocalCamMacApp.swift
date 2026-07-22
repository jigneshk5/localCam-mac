import SwiftUI

@main
struct LocalCamMacApp: App {
    @StateObject private var store = CameraStore()
    @State private var screenshotMessage: ScreenshotMessage?

    init() {
#if DEBUG
        let hasDiagnosticURL = ProcessInfo.processInfo.environment["LOCAL_CAM_RTSP_DIAGNOSTIC_URL"] != nil
        NSLog("[LocalCam][Diagnostic] app launched, diagnostic URL present=%@", hasDiagnosticURL ? "true" : "false")
        UserDefaults.standard.set(hasDiagnosticURL, forKey: "local-cam.debug.diagnostic-url-present")
#endif
    }

    var body: some Scene {
        Window("Local Cam", id: "main") {
            rootView
                .preferredColorScheme(.light)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
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

    @ViewBuilder
    private var rootView: some View {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["LOCAL_CAM_RTSP_DIAGNOSTIC_URL"],
           let url = URL(string: value) {
            RTSPDiagnosticView(url: url)
                .frame(minWidth: 960, minHeight: 600)
        } else {
            standardContent
        }
#else
        standardContent
#endif
    }

    private var standardContent: some View {
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

    private func captureScreenshot() {
        Task {
            do {
                let url = try await ScreenshotCaptureService.captureActiveWindow()
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
}

#if DEBUG
private struct RTSPDiagnosticView: View {
    @StateObject private var controller: RTSPPlayerController

    init(url: URL) {
        _controller = StateObject(wrappedValue: RTSPPlayerController(rtspURL: url))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            VLCVideoContainerView(controller: controller)
            Text(controller.errorMessage ?? controller.statusText)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
        .task { controller.play() }
        .onDisappear { controller.stop() }
    }
}
#endif

private struct ScreenshotMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
