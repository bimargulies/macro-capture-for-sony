import AppKit
import SwiftUI

struct FrameViewRepresentable: NSViewRepresentable {
    let view: FrameView
    func makeNSView(context: Context) -> FrameView { view }
    func updateNSView(_ nsView: FrameView, context: Context) {}
}

/// Large millisecond clock for glass-to-glass latency tests: point the camera at this
/// window; the viewfinder shows an older copy of the clock, and the difference is the latency.
struct ClockOverlay: View {
    var body: some View {
        TimelineView(.animation) { _ in
            let ms = Int(Date().timeIntervalSinceReferenceDate * 1000) % 100000
            Text(String(format: "%02d.%03d", ms / 1000, ms % 1000))
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
                .padding(8)
                .background(Color.black.opacity(0.7))
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: CameraModel
    let showClock = CommandLine.arguments.contains("--clock")
    var body: some View {
        VStack(spacing: 0) {
            FrameViewRepresentable(view: model.frameView)
                .frame(minWidth: 640, minHeight: 480)
                .overlay(alignment: .topLeading) { if showClock { ClockOverlay() } }
                .overlay {
                    if model.state != .connected {
                        ZStack {
                            Color.black.opacity(0.6)
                            VStack(spacing: 12) {
                                Text(model.state == .reconnecting ? "Reconnecting…" : "Camera not connected")
                                    .font(.title2).foregroundColor(.white)
                                Text(model.status).font(.callout).foregroundColor(.gray)
                            }
                        }
                    }
                }
            HStack {
                Text(model.status)
                Spacer()
                Text(model.statsLine).font(.system(.caption, design: .monospaced))
            }
            .padding(8)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CameraModel()
    private var sigSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer logs even when redirected
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.start()

        // Always release the camera session, even on Ctrl-C / kill.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            sigSources.append(src)
        }

        // Optional: --seconds N quits automatically (for scripted measurements).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let n = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ViewfinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Viewfinder") {
            ContentView(model: delegate.model)
        }
    }
}
