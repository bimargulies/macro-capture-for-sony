import AppKit
import CaptureCore
import SwiftUI

/// Invisible view that restores its window to the saved position and keeps that position up to date.
struct WindowPlacementAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowPlacementNSView { WindowPlacementNSView() }
    func updateNSView(_ nsView: WindowPlacementNSView, context: Context) {}
}

final class WindowPlacementNSView: NSView {
    /// SwiftUI can still reposition a new window just after it appears, so the restore is applied again after this.
    private static let settleSeconds = 0.3

    private let placement = WindowPlacement(defaults: .standard)
    private var observers: [NSObjectProtocol] = []
    private var saving = false
    private var settleGeneration = 0

    private var screenFrames: [CGRect] { NSScreen.screens.map(\.frame) }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        saving = false
        guard let window else { return }
        window.setFrameAutosaveName("")  // this view is now the only thing saving the position

        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.saveFrame()
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.restoreAndSettle()
        })
        restoreAndSettle()
    }

    /// Saving stays off until the window has settled, so moves made by the system are not remembered.
    private func restoreAndSettle() {
        saving = false
        restore()
        settleGeneration += 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }
            self.restore()
            self.saving = true
        }
    }

    private func restore() {
        guard let window, let frame = placement.frame(screens: screenFrames), window.frame != frame,
              !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(frame, display: true)
    }

    private func saveFrame() {
        guard saving, let window, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        placement.save(window.frame, screens: screenFrames)
    }
}
