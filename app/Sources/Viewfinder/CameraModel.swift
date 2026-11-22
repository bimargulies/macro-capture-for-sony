import AppKit
import CCameraShim
import CaptureCore
import Foundation

/// A value shared between threads, guarded by a lock.
final class Locked<T> {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A shutter press whose photo has not been delivered yet.
private struct PendingShot {
    let id = UUID()
    var context: ShotContext
    var captured = false
}

/// Owns the camera connection, the shooting controls and the delivery of photos.
final class CameraModel: NSObject, ObservableObject, CameraBridgeDelegate {
    @Published var status = "Connecting…"
    @Published var state: CameraBridgeState = .reconnecting  // shown as "not live" until first connect
    @Published var statsLine = ""

    // Shooting
    @Published var halfPressed = false
    @Published var shotsInFlight = 0
    /// A shutter press has been sent but the camera has not yet reported taking the photo.
    @Published var awaitingCapture = false
    @Published var stackOpen = false
    @Published var lastMessage = ""
    @Published var errorMessage: String?
    @Published var lastDelivered: URL?

    /// Which tab is showing: the live viewfinder (false) or the viewer of exploring photos (true).
    @Published var showViewer = CommandLine.arguments.contains("--viewer")
    let viewer: ViewerModel

    /// Bottom-line exposure readout: shutter, aperture, ISO, compensation.
    @Published var exposureLine = ""

    // Focus magnifier. Ratio 0 = off, else tenths of a power (47 = x4.7).
    @Published var magnifierRatios: [UInt32] = []
    @Published var magnifierRatio: UInt32 = 0
    /// Ratio used when a click turns the magnifier on; the last one chosen.
    private(set) var preferredRatio: UInt32 = 0
    /// Magnifier centre as a fraction of the unrotated full picture (0...1, origin top-left).
    private(set) var magnifierCenter = CGPoint(x: 0.5, y: 0.5)
    private let magQueue = DispatchQueue(label: "camera.magnifier")
    private let magLock = NSLock()
    private var magWanted: (ratio: UInt32, x: Int, y: Int)?

    let settings: AppSettings
    let frameView = FrameView(frame: .zero)
    private let bridge = CameraBridge()
    private let exiftool = ExifTool.locate()
    private let pipeline: DeliveryPipeline

    // All of this is touched on the main thread only.
    private var pending: [PendingShot] = []
    private var failed: [(url: URL, context: ShotContext)] = []
    private var lastCameraTime: NaiveTime?
    /// `forced` comes from the Stack menu: it repairs a stack the app no longer knows about, so it leaves `stackOpen` alone.
    private enum MarkerRequest: String { case opening, closing, forced }
    private var markerQueue: [MarkerRequest] = []
    /// Photos on this Mac still being copied to their destination.
    private var deliveriesInFlight = 0
    /// True until the photos left in staging by a previous run have been delivered.
    private var recoveringStaged = false
    private let stagedStore = StagedRecovery(staging: AppFolders.staging)
    private let usesIsolatedDefaults: Bool

    /// Work that quitting would interrupt.
    var hasUnfinishedDeliveries: Bool {
        !pending.isEmpty || deliveriesInFlight > 0 || recoveringStaged || (!markerQueue.isEmpty && failed.isEmpty)
    }

    /// A press with no capture signal after this long did not fire (the camera may have been busy).
    var captureTimeoutSeconds = 8.0
    /// A captured photo that has not arrived after this long is given up on.
    var transferTimeoutSeconds = 180.0

    /// How long to hold the half-press before the full press, for the camera to settle (focus, metering).
    /// With manual focus 1 s is plenty; the true minimum has not been measured.
    var halfPressSettleSeconds = 1.0

    // Stats (touched only on the main thread via onDisplayed).
    private var frames = 0, totalFrames = 0
    private var latencySum = 0.0, latencyMax = 0.0, decodeSum = 0.0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var allLatencies: [Double] = []
    var logToStdout = true

    // Connect/disconnect and shutter work runs on serial queues, never on an SDK callback thread.
    private let ctl = DispatchQueue(label: "camera.control")
    private let shutterQueue = DispatchQueue(label: "camera.shutter")
    private let wantConnectedBox = Locked(true)
    fileprivate var wantConnected: Bool {
        get { wantConnectedBox.value }
        set { wantConnectedBox.value = newValue }
    }
    /// True while the camera is connected; safe to read from any queue (unlike `state`, which is main-thread only).
    private let connectedBox = Locked(false)
    private var recovering = false

    /// `isolatedDefaults`: use a throwaway preferences suite (for `--autotest`).
    init(isolatedDefaults: Bool = false) {
        usesIsolatedDefaults = isolatedDefaults
        if isolatedDefaults {
            let suite = "capture-viewfinder-autotest"
            UserDefaults().removePersistentDomain(forName: suite)
            settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        } else {
            settings = AppSettings()
        }
        pipeline = DeliveryPipeline(exiftool: exiftool, exploringDirectory: AppFolders.exploring)
        viewer = ViewerModel(library: ExploringLibrary(directory: AppFolders.exploring), exiftool: exiftool,
                             defaults: isolatedDefaults ? UserDefaults(suiteName: "capture-viewfinder-autotest")! : .standard)
        super.init()
        lastCameraTime = settings.lastCameraTime
        bridge.delegate = self
        // A click only marks the spot; choosing a magnification then centres on it.
        frameView.onClick = { [weak self] p in self?.magnifierCenter = p }
        frameView.onDoubleClick = { [weak self] p in self?.magnifyForDoubleClick(at: p) }
        frameView.onMagnifiedClick = { [weak self] in self?.toggleMagnifierPower() }
        frameView.onMagnifiedDoubleClick = { [weak self] in self?.setMagnifier(ratio: 0) }
        frameView.onDisplayed = { [weak self] latency, decode, size in self?.record(latency, decode, size) }
        try? FileManager.default.createDirectory(at: AppFolders.staging, withIntermediateDirectories: true)
        viewer.reload()
        if exiftool == nil { print("WARNING: ExifTool not found; camera capture times cannot be read (stack markers need them).") }
    }

    var exifToolAvailable: Bool { exiftool != nil }

    // MARK: Connection

    func start() {
        recoverStagedPhotos()  // lists the folder first, so a new download cannot be mistaken for a leftover
        ctl.async { self.connectLoop() }
        startMagnifierWatch()
        startExposureWatch()
    }

    /// Delivers photos a previous run left in staging, oldest first. Markers wait until this is done.
    /// A photo with no saved context predates the context files and is treated as a capture.
    private func recoverStagedPhotos() {
        guard !usesIsolatedDefaults else { return }  // an autotest must not send real leftovers to its scratch folder
        let store = stagedStore
        let files = store.stagedPhotos()
        let destination = settings.destinationURL
        let description = settings.photoDescription
        recoveringStaged = true
        Task {
            store.removeOrphanContexts()
            let contexts = Dictionary(uniqueKeysWithValues: files.map { file in
                (file, store.context(for: file) ?? ShotContext(mode: .capture, destination: destination, description: description))
            })
            for dir in Set(contexts.values.compactMap(\.destination) + [destination].compactMap { $0 }) {
                StagedRecovery.removeAbandonedPartials(in: dir)
            }
            for file in await self.pipeline.inCaptureOrder(files) {
                guard let context = contexts[file] else { continue }
                await MainActor.run { self.deliveriesInFlight += 1 }
                await self.performDelivery(file, context, showInViewer: false)
            }
            await MainActor.run {
                self.recoveringStaged = false
                if !files.isEmpty { self.lastMessage = "Recovered \(files.count) photo(s) left from the previous run." }
                self.drainMarkers()
            }
        }
    }

    /// Keeps trying until connected (or shutdown). Runs on `ctl`.
    private func connectLoop() {
        recovering = true
        defer { recovering = false }
        while wantConnected {
            setStatus("Connecting…", .reconnecting)
            do {
                try bridge.connect()
                try? bridge.setSaveFolder(AppFolders.staging.path)
                return  // the Connected state arrives via the delegate
            } catch {
                let msg = error.localizedDescription
                print("CONNECT FAILED: \(msg)")
                setStatus("\(msg) Retrying in 5 s…", .disconnected)
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    private func setStatus(_ message: String, _ newState: CameraBridgeState) {
        connectedBox.value = newState == .connected
        DispatchQueue.main.async {
            self.status = message
            self.state = newState
            if newState != .connected { self.statsLine = ""; self.halfPressed = false }
        }
    }

    /// Must run before the process exits so the camera releases its session.
    func shutdown() {
        wantConnected = false
        if magnifierRatio != 0 { magQueue.sync { try? self.bridge.setMagnifierRatio(0, x: 320, y: 240) } }
        ctl.sync { self.bridge.disconnect(); self.bridge.releaseSDK() }
        printSummary()
    }

    // MARK: Magnifier

    /// Magnifies at `center` (fractions of the full picture), or turns the magnifier off with ratio 0.
    /// Commands are coalesced: while the camera is busy only the newest request is kept.
    func setMagnifier(ratio: UInt32, center: CGPoint? = nil) {
        guard state == .connected else { return }
        if let center {
            magnifierCenter = CGPoint(x: min(max(center.x, 0), 1), y: min(max(center.y, 0), 1))
        }
        if ratio != 0 { preferredRatio = ratio }
        magnifierRatio = ratio
        frameView.magnified = ratio != 0
        let x = Int((magnifierCenter.x * 639).rounded()), y = Int((magnifierCenter.y * 479).rounded())
        magLock.lock()
        let idle = magWanted == nil
        magWanted = (ratio, x, y)
        magLock.unlock()
        if idle { magQueue.async { self.drainMagnifier() } }
    }

    // Viewfinder click powers, in tenths as the camera reports them.
    private static let lowMagnifierPower = 47
    private static let highMagnifierPower = 93

    /// The power the camera lists closest to `wanted` (the list can differ from one lens or setting to another).
    private func closestMagnifierRatio(to wanted: Int) -> UInt32? {
        magnifierRatios.min { abs(Int($0) - wanted) < abs(Int($1) - wanted) }
    }

    /// Double-click on the viewfinder: magnify there at ×4.7.
    private func magnifyForDoubleClick(at point: CGPoint) {
        guard let ratio = closestMagnifierRatio(to: Self.lowMagnifierPower) else {
            lastMessage = "The magnifier is not available yet."
            return
        }
        setMagnifier(ratio: ratio, center: point)
    }

    /// Single click while magnified: ×9.3, or back to ×4.7 if already there. Stays on the same spot.
    private func toggleMagnifierPower() {
        guard magnifierRatio != 0,
              let low = closestMagnifierRatio(to: Self.lowMagnifierPower),
              let high = closestMagnifierRatio(to: Self.highMagnifierPower) else { return }
        setMagnifier(ratio: magnifierRatio == high ? low : high)
    }

    private func drainMagnifier() {
        while true {
            magLock.lock()
            let want = magWanted
            magWanted = nil
            magLock.unlock()
            guard let want else { return }
            do { try bridge.setMagnifierRatio(want.ratio, x: Int32(want.x), y: Int32(want.y)) }
            catch { DispatchQueue.main.async { self.lastMessage = "Magnifier: \(error.localizedDescription)" } }
        }
    }

    /// Turn the ratio list and state over after (re)connecting; the camera starts un-magnified.
    private func refreshMagnifier() {
        // The Connected callback arrives while the camera is still settling, so early reads can come back
        // empty; retry for a few seconds.
        magQueue.async {
            var ratios: [UInt32] = []
            for attempt in 0..<15 {
                ratios = self.bridge.magnifierRatios().map { $0.uint32Value }
                if !ratios.isEmpty { break }
                print("magnifier ratios not available yet (attempt \(attempt + 1))")
                Thread.sleep(forTimeInterval: 1)
            }
            print("magnifier ratios: \(ratios)")
            DispatchQueue.main.async {
                self.magnifierRatios = ratios
                if !ratios.contains(self.preferredRatio) { self.preferredRatio = ratios.first ?? 0 }
            }
        }
    }

    /// The camera can drop out of magnification by itself (after a reconnect, or around shooting).
    /// The chosen power is the user's intent, so put it back whenever the camera disagrees.
    private func startMagnifierWatch() {
        // Runs on the main thread (where the UI state lives); only the camera read happens on magQueue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wantConnected else { return }
            self.magLock.lock(); let busy = self.magWanted != nil; self.magLock.unlock()
            if self.state == .connected && !busy {
                let desired = self.magnifierRatio
                let c = self.magnifierCenter
                self.magQueue.async {
                    let actual = self.bridge.currentMagnifierRatio()
                    guard actual >= 0, UInt32(actual) != desired else { return }
                    self.magLock.lock(); let newer = self.magWanted != nil; self.magLock.unlock()
                    if newer { return }  // the user just changed it; do not fight that
                    print("magnifier: camera at \(actual), wanted \(desired); restoring")
                    try? self.bridge.setMagnifierRatio(desired, x: Int32((c.x * 639).rounded()), y: Int32((c.y * 479).rounded()))
                }
            }
            self.startMagnifierWatch()
        }
    }

    // MARK: Exposure readout

    private let exposureQueue = DispatchQueue(label: "camera.exposure")
    private var exposureLogged = false

    /// Reads the exposure settings twice a second while connected.
    private func startExposureWatch() {
        exposureQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.wantConnected else { return }
            if self.connectedBox.value {
                let raw = self.bridge.readExposure()
                if !self.exposureLogged && !raw.isEmpty {
                    self.exposureLogged = true
                    print("exposure raw: " + raw.map { String(format: "0x%x=0x%llx", $0.key.uint32Value, $0.value.uint64Value) }.sorted().joined(separator: " "))
                }
                let line = Self.format(raw)
                DispatchQueue.main.async { if self.exposureLine != line { self.exposureLine = line } }
            } else {
                DispatchQueue.main.async { if !self.exposureLine.isEmpty { self.exposureLine = "" } }
            }
            self.startExposureWatch()
        }
    }

    private static func format(_ raw: [NSNumber: NSNumber]) -> String {
        func val(_ code: UInt32) -> UInt64? { raw[NSNumber(value: code)]?.uint64Value }
        var parts: [String] = []
        if let v = val(CameraBridgePropShutterSpeed), let t = ExposureText.shutter(v) { parts.append(t) }
        if let v = val(CameraBridgePropFNumber), let t = ExposureText.aperture(v) { parts.append(t) }
        if let v = val(CameraBridgePropISO), let t = ExposureText.iso(v) { parts.append(t) }
        if let v = val(CameraBridgePropExposureBias) { parts.append("comp " + ExposureText.ev(v)) }
        return parts.joined(separator: "   ")
    }

    // MARK: Shutter

    /// Hold (true) or release (false) the half-press, like the physical button.
    func setHalfPress(_ pressed: Bool) {
        guard state == .connected, pressed != halfPressed else { return }
        halfPressed = pressed
        shutterQueue.async {
            do { try self.bridge.setHalfPress(pressed) }
            catch { DispatchQueue.main.async { self.halfPressed = false; self.errorMessage = error.localizedDescription } }
        }
    }

    /// Full press. If the half-press is not already held, holds it briefly first (the camera
    /// will not fire on a full press alone).
    func shoot() {
        guard state == .connected else { errorMessage = "The camera is not connected."; return }
        if settings.mode == .capture && settings.destinationURL == nil {
            errorMessage = "Capture mode needs a destination folder. Choose one in Settings (⌘,)."
            return
        }
        // One press at a time until the camera reports the photo: otherwise a capture signal could not be
        // matched to the shot (and its description) it belongs to.
        if pending.contains(where: { !$0.captured }) {
            errorMessage = "The previous shot has not been taken yet."
            return
        }
        let ctx = ShotContext(mode: settings.mode, destination: settings.destinationURL,
                              description: settings.photoDescription, macTime: .local())
        let shot = PendingShot(context: ctx)
        pending.append(shot)
        updatePendingState()
        let alreadyHeld = halfPressed
        let settle = halfPressSettleSeconds
        shutterQueue.async {
            do {
                if !alreadyHeld {
                    try self.bridge.setHalfPress(true)
                    Thread.sleep(forTimeInterval: settle)
                }
                try self.bridge.fullPress()
                if !alreadyHeld {
                    Thread.sleep(forTimeInterval: 0.3)
                    try self.bridge.setHalfPress(false)
                }
                // The commands were accepted; now the camera must confirm that it took the photo.
                DispatchQueue.main.asyncAfter(deadline: .now() + self.captureTimeoutSeconds) {
                    self.expire(shot.id, ifCaptured: false,
                                message: "The camera did not take the photo (no capture signal within \(Int(self.captureTimeoutSeconds)) s). It may have been busy; try again.")
                }
            } catch {
                try? self.bridge.setHalfPress(false)
                DispatchQueue.main.async {
                    self.remove(shot.id)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updatePendingState() {
        shotsInFlight = pending.count
        awaitingCapture = pending.contains { !$0.captured }
    }

    private func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
        updatePendingState()
        drainMarkers()
    }

    /// Gives up on a shot that is still in the same state (not captured / captured but not delivered).
    private func expire(_ id: UUID, ifCaptured captured: Bool, message: String) {
        guard let shot = pending.first(where: { $0.id == id }), shot.captured == captured else { return }
        remove(id)
        errorMessage = message
    }

    // MARK: Stacks

    /// Start or stop a focus stack by writing a black marker photo into the destination.
    func toggleStack() {
        guard settings.mode == .capture, settings.destinationURL != nil else {
            errorMessage = "Stacks are marked in capture mode, with a destination folder set."
            return
        }
        guard lastCameraTime != nil else {
            errorMessage = "Take one photo first: a marker is stamped just after the previous photo's own time, so it sorts correctly whatever the camera's clock says."
            return
        }
        markerQueue.append(stackOpen ? .closing : .opening)
        stackOpen.toggle()
        retryFailed()
        drainMarkers()
    }

    /// Writes one marker without changing the app's stack state, e.g. to close a stack left open across a restart.
    /// The importer pairs markers, so this flips whatever state it is in.
    func writeForcedMarker() {
        guard settings.destinationURL != nil else {
            errorMessage = "A marker needs a destination folder. Choose one in Settings (⌘,)."
            return
        }
        guard lastCameraTime != nil else {
            errorMessage = "Take one photo first: a marker is stamped just after the previous photo's own time."
            return
        }
        markerQueue.append(.forced)
        retryFailed()
        drainMarkers()
    }

    /// Markers wait until every photo still in flight has been delivered: the importer closes a
    /// stack at the closing marker, so a photo arriving after it would end up outside the stack.
    /// That includes photos still copying to the destination and captures whose delivery failed.
    private func drainMarkers() {
        guard pending.isEmpty, deliveriesInFlight == 0, !recoveringStaged,
              !failed.contains(where: { $0.context.mode == .capture }),
              !markerQueue.isEmpty, let dir = settings.destinationURL, let last = lastCameraTime else { return }
        let request = markerQueue.removeFirst()
        // 1 ms after the previous photo or marker: sorts right after it, before whatever comes next.
        let t = last.advanced(by: 0.001)
        lastCameraTime = t
        settings.lastCameraTime = t
        Task {
            do {
                let url = try await self.pipeline.deliverMarker(at: t, into: dir)
                await MainActor.run {
                    self.lastMessage = "Wrote \(request.rawValue) marker \(url.lastPathComponent)"
                    self.drainMarkers()
                }
            } catch {
                await MainActor.run {
                    if request != .forced { self.stackOpen = request == .closing }  // it did not happen
                    self.lastCameraTime = self.settings.lastCameraTime  // the time slot was not used
                    self.errorMessage = "\(error)"
                    self.drainMarkers()
                }
            }
        }
    }

    // MARK: CameraBridgeDelegate (SDK thread)

    func cameraBridge(_ bridge: CameraBridge, didReceiveFrame jpeg: Data, arrivalNanos: UInt64) {
        frameView.submit(jpeg: jpeg, arrivalNanos: arrivalNanos)
    }

    func cameraBridge(_ bridge: CameraBridge, didChange newState: CameraBridgeState, message: String) {
        print("STATE: \(newState.rawValue) \(message)")
        let text = newState == .connected ? "Connected: \(bridge.modelName ?? "camera")" : message
        setStatus(text, newState)
        if newState == .connected {
            ctl.async { try? bridge.setSaveFolder(AppFolders.staging.path) }  // reapply after an SDK reconnect
            refreshMagnifier()
            if let note = bridge.transferNote { DispatchQueue.main.async { self.lastMessage = note } }
        }
        if newState == .disconnected {
            // The SDK gave up: tear down and start our own retry loop.
            ctl.async {
                guard self.wantConnected, !self.recovering else { return }
                Thread.sleep(forTimeInterval: 2)
                self.bridge.disconnect()
                self.connectLoop()
            }
        }
    }

    func cameraBridgeDidCapture(_ bridge: CameraBridge) {
        DispatchQueue.main.async {
            if let i = self.pending.firstIndex(where: { !$0.captured }) {
                self.pending[i].captured = true
                self.pending[i].context.macTime = .local()  // when the exposure happened, for clock learning
                let id = self.pending[i].id
                DispatchQueue.main.asyncAfter(deadline: .now() + self.transferTimeoutSeconds) {
                    self.expire(id, ifCaptured: true,
                                message: "A photo was taken but never arrived on this Mac (no transfer after \(Int(self.transferTimeoutSeconds)) s). It should still be on the camera's card.")
                }
            }
            self.updatePendingState()
            self.lastMessage = "Captured; transferring…"
        }
    }

    func cameraBridge(_ bridge: CameraBridge, didDownloadFile path: String) {
        DispatchQueue.main.async { self.handleDownload(URL(fileURLWithPath: path)) }
    }

    // MARK: Delivery (main thread)

    private func handleDownload(_ staged: URL) {
        // Photos arrive in the order they were shot; use what was decided at the shutter press.
        let ctx: ShotContext
        let firedFromApp = !pending.isEmpty
        if firedFromApp { ctx = pending.removeFirst().context }
        else { ctx = ShotContext(mode: settings.mode, destination: settings.destinationURL, description: settings.photoDescription) }
        updatePendingState()
        stagedStore.remember(ctx, for: staged)
        deliver(staged, ctx, showInViewer: firedFromApp && ctx.mode == .exploring)
    }

    /// `showInViewer` flips to the viewer tab when the photo lands. Not while the half-press is held:
    /// removing the capture tab would lose the button's mouse-up and leave the camera half-pressed.
    private func deliver(_ staged: URL, _ ctx: ShotContext, showInViewer: Bool = false) {
        deliveriesInFlight += 1
        Task { await self.performDelivery(staged, ctx, showInViewer: showInViewer) }
    }

    /// The caller has already counted this delivery in `deliveriesInFlight`.
    private func performDelivery(_ staged: URL, _ ctx: ShotContext, showInViewer: Bool) async {
            do {
                let result = try await self.pipeline.deliver(staged: staged, context: ctx)
                await MainActor.run {
                    self.deliveriesInFlight -= 1
                    self.stagedStore.forget(staged)
                    if let cam = result.cameraTime, self.lastCameraTime == nil || cam > self.lastCameraTime! {
                        self.lastCameraTime = cam
                        self.settings.lastCameraTime = cam
                    }
                    if let warning = result.warning { self.errorMessage = warning }
                    self.lastDelivered = result.url
                    if result.mode == .exploring { self.viewer.reload(selecting: result.url.lastPathComponent) }
                    if showInViewer && !self.halfPressed { self.showViewer = true }
                    self.lastMessage = (result.mode == .capture ? "Saved " : "Explored ") + result.url.lastPathComponent
                    self.drainMarkers()
                    self.retryFailed()
                }
            } catch {
                await MainActor.run {
                    self.deliveriesInFlight -= 1
                    self.failed.append((staged, ctx))
                    self.errorMessage = "\(error) The photo is kept in \(AppFolders.staging.path) and will be retried."
                    self.drainMarkers()
                }
            }
    }

    /// Retry photos whose delivery failed (e.g. the destination drive was not mounted).
    func retryFailed() {
        let items = failed
        failed.removeAll()
        for item in items {
            var context = item.context
            // A recovered photo may have had no destination yet; use the one chosen since.
            if context.mode == .capture && context.destination == nil { context.destination = settings.destinationURL }
            deliver(item.url, context)
        }
    }

    /// Copies the photo selected in the viewer to the destination folder, as a capture (with the description).
    func captureSelected() {
        guard let item = viewer.selected else { return }
        guard let dir = settings.destinationURL else {
            errorMessage = "Choose a destination folder first (Settings, ⌘,)."
            return
        }
        let description = settings.photoDescription
        Task {
            do {
                let result = try await pipeline.promote(exploring: item.url, description: description, into: dir)
                await MainActor.run {
                    self.viewer.markCaptured(item.id)
                    if let w = result.warning { self.errorMessage = w }
                    self.lastMessage = "Saved \(result.url.lastPathComponent) (from \(item.url.lastPathComponent))"
                }
            } catch {
                await MainActor.run { self.errorMessage = "\(error)" }
            }
        }
    }

    // MARK: Stats (main thread)

    private func record(_ latency: Double, _ decode: Double, _ size: CGSize) {
        frames += 1; totalFrames += 1
        latencySum += latency; latencyMax = max(latencyMax, latency); decodeSum += decode
        allLatencies.append(latency)
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now - windowStart) / 1e9
        if dt >= 1.0 {
            let line = String(format: "%.0fx%.0f  %.1f fps  fetch→screen avg %.1f ms (max %.1f)  decode avg %.1f ms  dropped %d",
                              size.width, size.height, Double(frames) / dt, latencySum / Double(frames),
                              latencyMax, decodeSum / Double(frames), frameView.droppedFrames)
            statsLine = line
            if logToStdout { print(line) }
            frames = 0; latencySum = 0; latencyMax = 0; decodeSum = 0; windowStart = now
        }
    }

    private func printSummary() {
        guard !allLatencies.isEmpty else { print("SUMMARY: no frames displayed"); return }
        let s = allLatencies.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(q * Double(s.count)))] }
        print(String(format: "SUMMARY: %d frames shown, fetch→screen median %.1f ms, p95 %.1f ms, max %.1f ms, dropped %d",
                     totalFrames, p(0.5), p(0.95), s.last!, frameView.droppedFrames))
    }
}
