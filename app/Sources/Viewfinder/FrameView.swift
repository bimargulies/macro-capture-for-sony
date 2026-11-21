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
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
    }

    /// The picture lives in its own layer so it can be rotated inside the view.
    private let imageLayer = CALayer()

    /// Clockwise quarter turns (0...3) applied for display only; the camera is unaffected.
    var quarterTurns = 0 {
        didSet { quarterTurns = ((quarterTurns % 4) + 4) % 4; needsLayout = true }
    }

    // MARK: Mouse: pick the magnifier position

    /// Click (no drag) at a point of the full picture, as fractions 0...1 of the unrotated image.
    var onClick: ((CGPoint) -> Void)?
    /// Drag while magnified: movement as a fraction of the picture's width/height (unrotated image axes).
    var onDrag: ((CGSize) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var imageSize = CGSize(width: 4, height: 3)
    private var dragStart: NSPoint?
    private var lastDrag: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// View vector -> image-axis fractions of the displayed (aspect-fit, rotated) picture.
    private func imageFraction(ofViewVector v: CGVector) -> CGSize {
        // Undo the display rotation (clockwise turns): rotate counter-clockwise by the same angle.
        let a = CGFloat(quarterTurns) * .pi / 2
        let lx = v.dx * cos(a) - v.dy * sin(a)
        let ly = v.dx * sin(a) + v.dy * cos(a)
        let odd = quarterTurns % 2 == 1
        let lw = odd ? bounds.height : bounds.width, lh = odd ? bounds.width : bounds.height
        let s = min(lw / imageSize.width, lh / imageSize.height)
        return CGSize(width: lx / (imageSize.width * s), height: -ly / (imageSize.height * s))  // image y grows downward
    }

    private func imagePoint(_ p: NSPoint) -> CGPoint {
        let f = imageFraction(ofViewVector: CGVector(dx: p.x - bounds.midX, dy: p.y - bounds.midY))
        return CGPoint(x: min(max(f.width + 0.5, 0), 1), y: min(max(f.height + 0.5, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { onDoubleClick?(); dragStart = nil; return }
        dragStart = p; lastDrag = p; dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let last = lastDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragged && hypot(p.x - start.x, p.y - start.y) < 4 { return }
        dragged = true
        let f = imageFraction(ofViewVector: CGVector(dx: p.x - last.x, dy: p.y - last.y))
        lastDrag = p
        onDrag?(f)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; lastDrag = nil }
        guard let start = dragStart, !dragged else { return }
        onClick?(imagePoint(start))
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // For 90/270 the layer is laid out with width and height swapped, then turned,
        // so the rotated picture still fits the view.
        let odd = quarterTurns % 2 == 1
        imageLayer.bounds = CGRect(x: 0, y: 0, width: odd ? b.height : b.width, height: odd ? b.width : b.height)
        imageLayer.position = CGPoint(x: b.midX, y: b.midY)
        imageLayer.transform = CATransform3DMakeRotation(-CGFloat(quarterTurns) * .pi / 2, 0, 0, 1)
        CATransaction.commit()
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

    /// Remember the full (un-magnified) picture's shape for click mapping.
    var magnified = false
    private func lastFullSize(_ img: CGImage) {
        if !magnified { imageSize = CGSize(width: img.width, height: img.height) }
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
        imageLayer.contents = img
        CATransaction.commit()

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if img.width > 0 { lastFullSize(img) }
        onDisplayed?(Double(now &- frame.arrival) / 1e6, Double(t1 - t0) / 1e6, CGSize(width: img.width, height: img.height))
    }
}
