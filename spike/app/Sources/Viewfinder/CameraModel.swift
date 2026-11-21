import AppKit
import CCameraShim
import Foundation

/// Owns the camera connection and aggregates statistics for the UI.
final class CameraModel: NSObject, ObservableObject, CameraBridgeDelegate {
    @Published var status = "Connecting…"
    @Published var state: CameraBridgeState = .reconnecting  // shown as "not live" until first connect
    @Published var statsLine = ""

    let frameView = FrameView(frame: .zero)
    private let bridge = CameraBridge()

    // Stats (touched only on the main thread via onDisplayed).
    private var frames = 0, totalFrames = 0
    private var latencySum = 0.0, latencyMax = 0.0, decodeSum = 0.0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var allLatencies: [Double] = []
    private var imageSize = CGSize.zero
    var logToStdout = true

    override init() {
        super.init()
        bridge.delegate = self
        frameView.onDisplayed = { [weak self] latency, decode, size in self?.record(latency, decode, size) }
    }

    // All connect/disconnect work runs on this serial queue (never on an SDK callback thread).
    private let ctl = DispatchQueue(label: "camera.control")
    private var wantConnected = true
    private var recovering = false

    func start() { ctl.async { self.connectLoop() } }

    /// Keeps trying until connected (or shutdown). Runs on `ctl`.
    private func connectLoop() {
        recovering = true
        defer { recovering = false }
        while wantConnected {
            setStatus("Connecting…", .reconnecting)
            do {
                try bridge.connect()
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
        DispatchQueue.main.async {
            self.status = message
            self.state = newState
            if newState != .connected { self.statsLine = "" }  // don't show stale fps while not live
        }
    }

    /// Must run before the process exits so the camera releases its session.
    func shutdown() {
        wantConnected = false
        ctl.sync { self.bridge.disconnect(); self.bridge.releaseSDK() }
        printSummary()
    }

    // MARK: CameraBridgeDelegate (SDK thread)
    func cameraBridge(_ bridge: CameraBridge, didReceiveFrame jpeg: Data, arrivalNanos: UInt64) {
        frameView.submit(jpeg: jpeg, arrivalNanos: arrivalNanos)
    }

    func cameraBridge(_ bridge: CameraBridge, didChange newState: CameraBridgeState, message: String) {
        print("STATE: \(newState.rawValue) \(message)")
        let text = newState == .connected ? "Connected: \(bridge.modelName ?? "camera")" : message
        setStatus(text, newState)
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

    // MARK: Stats (main thread)
    private func record(_ latency: Double, _ decode: Double, _ size: CGSize) {
        imageSize = size
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
