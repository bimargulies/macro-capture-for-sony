import CaptureCore
import Foundation

/// User preferences, saved in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Where photos go: a local temporary folder (exploring) or the destination folder (capture).
    @Published var mode: CaptureMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    /// The capture-mode destination folder (a plain path; the app is not sandboxed).
    @Published var destinationPath: String { didSet { defaults.set(destinationPath, forKey: "destinationPath") } }
    /// Description written into each photo (kept until edited).
    @Published var photoDescription: String { didSet { defaults.set(photoDescription, forKey: "photoDescription") } }

    /// Display rotation of the viewfinder in clockwise quarter turns (0...3). Remembered.
    @Published var rotation: Int { didSet { defaults.set(rotation, forKey: "rotation") } }

    /// Shows a 4x5 crop frame on the live view. Remembered.
    @Published var showCropGuide: Bool { didSet { defaults.set(showCropGuide, forKey: "showCropGuide") } }

    /// Shows the live view's frame rate, latency, decode time and dropped frames at the bottom right. Off by default;
    /// the numbers are always measured, so turning it on needs no restart.
    @Published var showLiveViewStats: Bool { didSet { defaults.set(showLiveViewStats, forKey: "showLiveViewStats") } }

    /// `defaults` is replaced by a throwaway suite in `--autotest` runs so real preferences are untouched.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = CaptureMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .exploring
        destinationPath = defaults.string(forKey: "destinationPath") ?? ""
        photoDescription = defaults.string(forKey: "photoDescription") ?? ""
        rotation = ((defaults.integer(forKey: "rotation") % 4) + 4) % 4
        showLiveViewStats = defaults.bool(forKey: "showLiveViewStats")
        showCropGuide = defaults.bool(forKey: "showCropGuide")
    }

    var destinationURL: URL? {
        destinationPath.isEmpty ? nil : URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The camera's own timestamp of the last photo or marker delivered (remembered between runs).
    /// A marker is stamped 1 ms after it, so it sorts right after that photo whatever the clocks say.
    var lastCameraTime: NaiveTime? {
        get { (defaults.object(forKey: "lastCameraTimeMs") as? Int64).map { NaiveTime(milliseconds: $0) } }
        set { defaults.set(newValue?.milliseconds, forKey: "lastCameraTimeMs") }
    }
}

/// Folders the app owns.
enum AppFolders {
    private static let name = "Macro Capture for Sony"

    private static func support(_ sub: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(name).appendingPathComponent(sub)
    }
    /// Where the SDK writes photos before we route them. Never the final destination.
    static var staging: URL { support("staging") }
    /// Exploring-mode photos: local, and kept for a few days.
    static var exploring: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name).appendingPathComponent("exploring")
    }
}
