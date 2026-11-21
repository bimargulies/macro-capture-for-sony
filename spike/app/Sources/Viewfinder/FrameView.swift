import AppKit
import ImageIO

/// Shows the latest live-view frame in a CALayer. Frames arrive on the SDK thread;
/// we keep only the newest ("latest frame wins") and decode/display it on the main thread.
final class FrameView: NSView {
    private let lock = NSLock()
    private var pending: (data: Data, arrival: UInt64)?
    private var drainScheduled = false

    /// Called on the main thread after each frame is put on screen:
    /// (arrival-to-display milliseconds, decode milliseconds, image size).
    var onDisplayed: ((Double, Double, CGSize) -> Void)?
    /// Frames replaced before they were shown.
    private(set) var droppedFrames = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Thread-safe. Called from the camera thread.
    func submit(jpeg: Data, arrivalNanos: UInt64) {
        lock.lock()
        if pending != nil { droppedFrames += 1 }
        pending = (jpeg, arrivalNanos)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        lock.lock()
        let frame = pending
        pending = nil
        drainScheduled = false
        lock.unlock()
        guard let frame else { return }

        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let src = CGImageSourceCreateWithData(frame.data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return }
        let t1 = DispatchTime.now().uptimeNanoseconds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = img
        CATransaction.commit()

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        onDisplayed?(Double(now &- frame.arrival) / 1e6, Double(t1 - t0) / 1e6, CGSize(width: img.width, height: img.height))
    }
}
