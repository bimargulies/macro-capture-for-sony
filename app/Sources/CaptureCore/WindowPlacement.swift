import CoreGraphics
import Foundation

/// Remembers the main window's frame separately for each monitor layout, so that unplugging a monitor
/// (which makes macOS move the window) does not lose the position used when it is attached.
public struct WindowPlacement {
    private static let storageKey = "windowFramesByScreenLayout"
    /// How much of the top of the window must be on a screen for a saved frame to be usable.
    private static let titleBarHeight: CGFloat = 28

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Identifies a set of screens by their frames, regardless of the order they are listed in.
    public static func layoutKey(screens: [CGRect]) -> String {
        screens.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
            .sorted().joined(separator: "|")
    }

    public func save(_ frame: CGRect, screens: [CGRect]) {
        var all = defaults.dictionary(forKey: Self.storageKey) as? [String: [Double]] ?? [:]
        all[Self.layoutKey(screens: screens)] = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
        defaults.set(all, forKey: Self.storageKey)
    }

    /// The frame saved for this layout, if its title bar would be on one of the screens.
    public func frame(screens: [CGRect]) -> CGRect? {
        let all = defaults.dictionary(forKey: Self.storageKey) as? [String: [Double]]
        guard let v = all?[Self.layoutKey(screens: screens)], v.count == 4 else { return nil }
        let frame = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - Self.titleBarHeight, width: frame.width, height: Self.titleBarHeight)
        return screens.contains { $0.intersects(titleBar) } ? frame : nil
    }
}
