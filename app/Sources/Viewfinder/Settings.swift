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

    /// `defaults` is replaced by a throwaway suite in `--autotest` runs so real preferences are untouched.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = CaptureMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .exploring
        destinationPath = defaults.string(forKey: "destinationPath") ?? ""
        photoDescription = defaults.string(forKey: "photoDescription") ?? ""
    }

    var destinationURL: URL? {
        destinationPath.isEmpty ? nil : URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Camera clock minus Mac clock, in seconds; learned from each shot's EXIF time and remembered.
    var cameraClockOffset: Double? {
        get { defaults.object(forKey: "cameraClockOffset") as? Double }
        set { defaults.set(newValue, forKey: "cameraClockOffset") }
    }
}

/// Folders the app owns.
enum AppFolders {
    private static func support(_ sub: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Capture Viewfinder").appendingPathComponent(sub)
    }
    /// Where the SDK writes photos before we route them. Never the final destination.
    static var staging: URL { support("staging") }
    /// Exploring-mode photos: local, and kept for a few days.
    static var exploring: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Capture Viewfinder").appendingPathComponent("exploring")
    }
}
