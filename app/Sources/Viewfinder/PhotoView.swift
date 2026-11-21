import AppKit

/// Shows one large photo that can be zoomed (pinch, ⌥-scroll, double-click) and panned (scroll, drag).
/// Starts "fit to window"; double-click toggles to 100% (one image pixel per screen pixel) at the clicked
/// spot, which is what you want for judging focus.
final class PhotoView: NSView {
    private let imageLayer = CALayer()
    private var imagePixels = CGSize(width: 1, height: 1)
    /// Clockwise quarter turns for display (from the photo's EXIF orientation).
    private var turns = 0
    private var hasImage = false
    /// Display points per image pixel, and pan offset of the image centre from the view centre (view points).
    private var scale: CGFloat = 1
    private var pan = CGPoint.zero
    private var fitted = true
    private var dragLast: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Replaces the photo (nil clears it) and fits it to the window.
    func setImage(_ image: CGImage?, quarterTurns: Int) {
        hasImage = image != nil
        imageLayer.contents = image
        if let image { imagePixels = CGSize(width: image.width, height: image.height) }
        turns = quarterTurns
        fitted = true
        pan = .zero
        needsLayout = true
    }

    private var orientedSize: CGSize { turns % 2 == 1 ? CGSize(width: imagePixels.height, height: imagePixels.width) : imagePixels }
    private var fitScale: CGFloat { min(bounds.width / orientedSize.width, bounds.height / orientedSize.height) }
    private var fullScale: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    override func layout() {
        super.layout()
        if fitted { scale = fitScale; pan = .zero }
        clampPan()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.isHidden = !hasImage
        imageLayer.bounds = CGRect(origin: .zero, size: imagePixels)
        imageLayer.position = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
        imageLayer.transform = CATransform3DRotate(CATransform3DMakeScale(scale, scale, 1), -CGFloat(turns) * .pi / 2, 0, 0, 1)
        CATransaction.commit()
    }

    private func clampPan() {
        let w = orientedSize.width * scale, h = orientedSize.height * scale
        pan.x = w <= bounds.width ? 0 : min(max(pan.x, -(w - bounds.width) / 2), (w - bounds.width) / 2)
        pan.y = h <= bounds.height ? 0 : min(max(pan.y, -(h - bounds.height) / 2), (h - bounds.height) / 2)
    }

    /// Zooms to `newScale`, keeping the picture point under view point `p` fixed.
    private func zoom(to newScale: CGFloat, around p: NSPoint) {
        let s = min(max(newScale, fitScale), max(fullScale * 4, fitScale))
        let rx = p.x - bounds.midX, ry = p.y - bounds.midY
        let k = s / scale
        pan = CGPoint(x: rx - (rx - pan.x) * k, y: ry - (ry - pan.y) * k)
        scale = s
        fitted = abs(s - fitScale) < 0.0001
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        dragLast = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            let p = dragLast!
            zoom(to: fitted ? fullScale : fitScale, around: p)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let last = dragLast { pan.x += p.x - last.x; pan.y += p.y - last.y; fitted = false; needsLayout = true }
        dragLast = p
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            zoom(to: scale * (1 + event.scrollingDeltaY * 0.01), around: convert(event.locationInWindow, from: nil))
        } else {
            pan.x += event.scrollingDeltaX; pan.y -= event.scrollingDeltaY
            fitted = false
            needsLayout = true
        }
    }
    override func magnify(with event: NSEvent) {
        zoom(to: scale * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
