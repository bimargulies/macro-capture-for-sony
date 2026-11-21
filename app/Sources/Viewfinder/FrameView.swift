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
        setUpMarkers()
    }

    /// The picture lives in its own layer so it can be rotated inside the view.
    private let imageLayer = CALayer()

    /// Clockwise quarter turns (0...3) applied for display only; the camera is unaffected.
    var quarterTurns = 0 {
        didSet { quarterTurns = ((quarterTurns % 4) + 4) % 4; needsLayout = true }
    }

    // MARK: Mouse: pick the magnifier position

    /// Click at a point of the full picture, as fractions 0...1 of the unrotated image (origin top-left).
    var onClick: ((CGPoint) -> Void)?
    private var imageSize = CGSize(width: 4, height: 3)

    /// The spot chosen by a click (gray corners). Kept until the next click.
    private(set) var placed: CGPoint?
    /// Mouse position in the view while it is over the picture (orange corners), else nil.
    private var hover: NSPoint?
    /// Corner box size as a fraction of the displayed picture (fixed; the power is not known until after the click).
    private let boxFraction: CGFloat = 1 / 9.4

    /// While magnified the picture already shows the chosen area, so the corner marks are hidden.
    var magnified = false { didSet { needsLayout = true; window?.invalidateCursorRects(for: self) } }

    private let hoverLayer = CAShapeLayer()
    private let placedLayer = CAShapeLayer()

    private func setUpMarkers() {
        for (l, c) in [(placedLayer, NSColor.systemGray), (hoverLayer, NSColor.orange)] {
            l.fillColor = nil
            l.strokeColor = c.cgColor
            l.lineWidth = 2.5
            l.lineCap = .square
            l.zPosition = 10
            layer?.addSublayer(l)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let invisibleCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 16, height: 16))
        return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
    }()

    override func resetCursorRects() {
        if !magnified { addCursorRect(bounds, cursor: FrameView.invisibleCursor) }
    }

    /// Size of the displayed picture in view points, and the fit scale (view points per image pixel).
    private func displayedPictureSize() -> CGSize {
        let odd = quarterTurns % 2 == 1
        let lw = odd ? bounds.height : bounds.width, lh = odd ? bounds.width : bounds.height
        let s = min(lw / imageSize.width, lh / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return odd ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// View vector (from the view centre) to image fractions 0...1.
    private func imagePoint(_ p: NSPoint) -> CGPoint {
        let a = CGFloat(quarterTurns) * .pi / 2
        let vx = p.x - bounds.midX, vy = p.y - bounds.midY
        let lx = vx * cos(a) - vy * sin(a)
        let ly = vx * sin(a) + vy * cos(a)
        let odd = quarterTurns % 2 == 1
        let lw = odd ? bounds.height : bounds.width, lh = odd ? bounds.width : bounds.height
        let s = min(lw / imageSize.width, lh / imageSize.height)
        return CGPoint(x: min(max(lx / (imageSize.width * s) + 0.5, 0), 1),
                       y: min(max(-ly / (imageSize.height * s) + 0.5, 0), 1))
    }

    /// Image fractions to a point in the view.
    private func viewPoint(_ f: CGPoint) -> NSPoint {
        let odd = quarterTurns % 2 == 1
        let lw = odd ? bounds.height : bounds.width, lh = odd ? bounds.width : bounds.height
        let s = min(lw / imageSize.width, lh / imageSize.height)
        let lx = (f.x - 0.5) * imageSize.width * s
        let ly = -(f.y - 0.5) * imageSize.height * s
        let a = CGFloat(quarterTurns) * .pi / 2
        return NSPoint(x: bounds.midX + lx * cos(a) + ly * sin(a),
                       y: bounds.midY - lx * sin(a) + ly * cos(a))
    }

    /// Four corner brackets of a box centred on `c`, about the size of the area the magnifier would show.
    private func cornerPath(around c: NSPoint) -> CGPath {
        let pic = displayedPictureSize()
        let w = max(pic.width * boxFraction, 24), h = max(pic.height * boxFraction, 18)
        let arm = min(w, h) * 0.3
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let path = CGMutablePath()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        return path
    }

    private func updateMarkers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placedLayer.frame = bounds
        hoverLayer.frame = bounds
        if magnified { placedLayer.path = nil; hoverLayer.path = nil }
        else {
            placedLayer.path = placed.map { cornerPath(around: viewPoint($0)) }
            hoverLayer.path = hover.map { cornerPath(around: $0) }
        }
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        updateMarkers()
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hover = nil; updateMarkers() }

    override func mouseDown(with event: NSEvent) {
        guard !magnified else { return }
        let p = convert(event.locationInWindow, from: nil)
        let f = imagePoint(p)
        placed = f
        updateMarkers()
        onClick?(f)
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
        updateMarkers()
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
