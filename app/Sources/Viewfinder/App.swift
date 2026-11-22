import AppKit
import CaptureCore
import SwiftUI

struct FrameViewRepresentable: NSViewRepresentable {
    let view: FrameView
    let quarterTurns: Int
    let hidden: Bool
    func makeNSView(context: Context) -> FrameView { view }
    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.quarterTurns = quarterTurns
        nsView.isHidden = hidden   // hidden views also drop their cursor rects
    }
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

/// The half-press button works like the physical one: held while the mouse is down.
struct HalfPressButton: View {
    @ObservedObject var model: CameraModel
    @GestureState private var down = false
    var body: some View {
        Text("Half-press (hold)")
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(model.halfPressed ? Color.accentColor : Color.secondary.opacity(0.25))
            .foregroundColor(model.halfPressed ? .white : .primary)
            .cornerRadius(6)
            .opacity(model.state == .connected ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($down) { _, state, _ in state = true }
                    .onChanged { _ in model.setHalfPress(true) }
                    .onEnded { _ in model.setHalfPress(false) }
            )
            .help("Hold to focus and meter; the shutter button then fires immediately")
    }
}

struct ControlsView: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var settings: AppSettings

    private var connected: Bool { model.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $settings.mode) {
                    Text("Exploring").tag(CaptureMode.exploring)
                    Text("Capture").tag(CaptureMode.capture)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
                .help("Exploring keeps raw files in a local temporary folder. Capture adds the description and delivers them to the destination folder.")

                if settings.mode == .capture {
                    Image(systemName: "folder")
                    Text(settings.destinationPath.isEmpty ? "No destination folder (Settings, ⌘,)" : settings.destinationPath)
                        .lineLimit(1).truncationMode(.head)
                        .foregroundColor(settings.destinationPath.isEmpty ? .red : .secondary)
                } else {
                    Text("Raw files stay in a local temporary folder.").foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                HalfPressButton(model: model)
                Button("Shutter") { model.shoot() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!connected || model.awaitingCapture)
                    .help("Full press (⌘↩). Presses half-way first if you are not already holding the half-press.")
                Button { settings.rotation = (settings.rotation + 3) % 4 } label: { Image(systemName: "rotate.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Rotate the viewfinder image counter-clockwise (⌘[). Display only.")
                Button { settings.rotation = (settings.rotation + 1) % 4 } label: { Image(systemName: "rotate.right") }
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Rotate the viewfinder image clockwise (⌘]). Display only.")
                Text("Magnifier").foregroundColor(.secondary)
                Picker("Magnifier", selection: Binding(get: { model.magnifierRatio },
                                                       set: { model.setMagnifier(ratio: $0) })) {
                    Text("Off").tag(UInt32(0))
                    ForEach(model.magnifierRatios, id: \.self) { Text("×" + String(format: "%.1f", Double($0) / 10)).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                .disabled(!connected || model.magnifierRatios.isEmpty)
                .help("Focus magnifier. Click the picture to mark a spot (orange corners follow the mouse, gray corners stay), then choose a power to magnify there. Off or Esc to return.")
                Button("") { model.setMagnifier(ratio: 0) }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button(model.stackOpen ? "Stop stack" : "Start stack") { model.toggleStack() }
                    .disabled(!connected || settings.mode != .capture)
                    .help("Writes a black marker photo into the destination folder. Press again to close the stack.")
                if model.shotsInFlight > 0 {
                    ProgressView().controlSize(.small)
                    Text(model.awaitingCapture ? "waiting for the camera…" : "\(model.shotsInFlight) transferring")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack {
                Text("Description")
                TextField("Saved with each photo in a sidecar .xmp file (capture mode)", text: $settings.photoDescription)
                    .textFieldStyle(.roundedBorder)
                if !model.exifToolAvailable {
                    Text("ExifTool not found (needed to read capture times)").foregroundColor(.red)
                }
            }

            if let err = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
            } else if !model.lastMessage.isEmpty {
                Text(model.lastMessage).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(10)
    }
}

struct ContentView: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var settings: AppSettings
    let showClock = CommandLine.arguments.contains("--clock")
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("View", selection: $model.showViewer) {
                    Text("Capture").tag(false)
                    Text("Viewer").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                .help("Switch between the live view with the camera controls (⌘1) and the photos you have explored (⌘2). In Exploring mode, Tab switches too.")
                Button("") { model.showViewer = false }.keyboardShortcut("1", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button("") { model.showViewer = true }.keyboardShortcut("2", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Spacer()
            }
            .padding(6)
            Divider()
            if model.showViewer {
                ViewerView(model: model, viewer: model.viewer, settings: settings)
            } else {
                captureTab
            }
        }
        .background(WindowPlacementAccessor())
    }

    private var captureTab: some View {
        VStack(spacing: 0) {
            FrameViewRepresentable(view: model.frameView, quarterTurns: settings.rotation, hidden: false)
                .frame(minWidth: 360, minHeight: 360)
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
            Divider()
            ControlsView(model: model, settings: model.settings)
            Divider()
            HStack {
                Text(model.status)
                if !model.exposureLine.isEmpty {
                    Text(model.exposureLine).font(.system(.body, design: .monospaced)).padding(.leading, 12)
                }
                Spacer()
                Text(model.statsLine).font(.system(.caption, design: .monospaced))
            }
            .padding(8)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Capture destination") {
                HStack {
                    Text(settings.destinationPath.isEmpty ? "Not set" : settings.destinationPath)
                        .lineLimit(1).truncationMode(.head)
                        .foregroundColor(settings.destinationPath.isEmpty ? .red : .primary)
                    Spacer()
                    Button("Choose…") { choose() }
                }
                Text("In capture mode, photos (and stack markers) are placed here as finished files. The importer watches this folder.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Folders") {
                LabeledContent("Staging", value: AppFolders.staging.path)
                LabeledContent("Exploring", value: AppFolders.exploring.path)
            }
            Section("Tools") {
                LabeledContent("ExifTool", value: model.exifToolAvailable ? "found" : "not found")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 360)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.destinationPath = url.path
            model.retryFailed()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Stored properties initialize in order: this must stay above `model`, so a second copy exits before touching the SDK.
    private let singleInstance: Void = SingleInstance.enforce()
    let model = CameraModel(isolatedDefaults: CommandLine.arguments.contains("--autotest"))
    private var sigSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer logs even when redirected
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
        installTabSwitch()

        // Always release the camera session, even on Ctrl-C / kill.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            sigSources.append(src)
        }

        // --autotest <folder>: fire a few real shots through the whole pipeline, then quit.
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--autotest"), i + 1 < argv.count {
            model.runAutoTest(destination: URL(fileURLWithPath: argv[i + 1], isDirectory: true))
        }

        // Optional: --seconds N quits automatically (for scripted measurements).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let n = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) { NSApp.terminate(nil) }
        }
    }

    /// Tab flips between Capture and Viewer in Exploring mode. An event monitor, because a focused text
    /// field would otherwise take the key to move focus.
    private func installTabSwitch() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shouldSwitchTabs(on: event) else { return event }
            self.model.showViewer.toggle()
            return nil
        }
    }

    private func shouldSwitchTabs(on event: NSEvent) -> Bool {
        let tabKeyCode: UInt16 = 48
        guard event.keyCode == tabKeyCode,
              event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]),
              model.settings.mode == .exploring,
              !model.halfPressed,  // removing the capture tab would lose the half-press button's mouse-up
              let window = event.window, window.title == ViewfinderApp.windowTitle, window.attachedSheet == nil
        else { return false }
        // Mid-composition (e.g. Japanese input), Tab belongs to the input method.
        if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ViewfinderApp: App {
    static let windowTitle = "Macro Sony Capture"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(Self.windowTitle) {
            ContentView(model: delegate.model, settings: delegate.model.settings)
        }
        Settings {
            SettingsView(model: delegate.model, settings: delegate.model.settings)
        }
    }
}


/// The viewer tab: the selected exploring photo large, with a carousel of recent ones below.
struct ViewerView: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var viewer: ViewerModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PhotoViewRepresentable(image: viewer.large?.image, turns: viewer.large?.turns ?? 0, zoomer: viewer.zoomer)
                if viewer.loading { ProgressView().controlSize(.large) }
                else if viewer.items.isEmpty {
                    Text("No explored photos yet. Take one in Exploring mode.").foregroundColor(.gray)
                } else if let p = viewer.problem {
                    Text(p).foregroundColor(.red).padding()
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(viewer.selected?.url.lastPathComponent ?? "").font(.system(.callout, design: .monospaced))
                if viewer.selected?.captured == true { Label("captured", systemImage: "checkmark.circle.fill").foregroundColor(.green) }
                Spacer()
                Button { viewer.zoomer.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘-)")
                Button { viewer.zoomer.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+)")
                Button("Fit") { viewer.zoomer.fit() }.help("Fit the whole photo in the window")
                Button("100%") { viewer.zoomer.actualSize() }.help("One photo pixel per screen pixel (double-click also toggles this)")
                Divider().frame(height: 16)
                Button("◀") { viewer.step(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("▶") { viewer.step(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Capture this photo") { model.captureSelected() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(viewer.selected == nil)
                    .help("Copy this photo to the destination folder, with the description (⌘K). The explored copy stays here.")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            HStack {
                Text("Description")
                TextField("Saved with the photo when you capture it", text: $settings.photoDescription)
                    .textFieldStyle(.roundedBorder)
                if settings.destinationPath.isEmpty {
                    Text("No destination folder (Settings, ⌘,)").foregroundColor(.red)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            if let err = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            } else if !model.lastMessage.isEmpty {
                Text(model.lastMessage).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Carousel(viewer: viewer)
        }
        .background(Color.black)
    }
}

struct Carousel: View {
    @ObservedObject var viewer: ViewerModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(viewer.items) { item in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let t = item.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
                                else { Color.gray.opacity(0.3) }
                            }
                            .frame(width: 120, height: 80)
                            .background(Color.black)
                            if item.captured {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).padding(3)
                            }
                        }
                        .border(item.id == viewer.selectedID ? Color.orange : Color.clear, width: 3)
                        .id(item.id)
                        .onTapGesture { viewer.select(item.id) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { viewer.delete(item.id) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 96)
            .onChange(of: viewer.selectedID) { id in if let id { proxy.scrollTo(id) } }
            .onAppear { if let id = viewer.selectedID { proxy.scrollTo(id) } }
        }
    }
}

struct PhotoViewRepresentable: NSViewRepresentable {
    let image: CGImage?
    let turns: Int
    let zoomer: PhotoZoomer
    func makeNSView(context: Context) -> PhotoView { let v = PhotoView(frame: .zero); zoomer.view = v; return v }
    func updateNSView(_ v: PhotoView, context: Context) {
        // Only reset zoom when the picture itself changes.
        if context.coordinator.lastImage !== image.map({ $0 as AnyObject }) as AnyObject? {
            context.coordinator.lastImage = image.map { $0 as AnyObject }
            v.setImage(image, quarterTurns: turns)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastImage: AnyObject? }
}
