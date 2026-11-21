import Foundation

public enum ExifToolError: Error, CustomStringConvertible {
    case notFound
    case failed(status: Int32, stderr: String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notFound: return "ExifTool was not found (not bundled, and not installed at /opt/homebrew/bin or /usr/local/bin)."
        case .failed(let s, let e): return "ExifTool failed (exit \(s)): \(e.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .unreadable(let m): return m
        }
    }
}

/// Runs ExifTool as a subprocess. The app only ever *reads* ARW files with it (the capture time):
/// raw files are never rewritten, and descriptions travel in a sidecar `.xmp` (see PLAN.md).
public struct ExifTool: Sendable {
    let executable: URL
    let leadingArguments: [String]

    /// Finds ExifTool: first a copy bundled in the app (`<resources>/exiftool/exiftool` with its
    /// `lib` folder beside it, run with the system Perl), then a Homebrew or system install.
    public static func locate(bundledResources: URL? = Bundle.main.resourceURL) -> ExifTool? {
        let fm = FileManager.default
        if let r = bundledResources {
            let script = r.appendingPathComponent("exiftool/exiftool")
            if fm.isReadableFile(atPath: script.path), fm.isExecutableFile(atPath: "/usr/bin/perl") {
                return ExifTool(executable: URL(fileURLWithPath: "/usr/bin/perl"), leadingArguments: [script.path])
            }
        }
        for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"] where fm.isExecutableFile(atPath: path) {
            return ExifTool(executable: URL(fileURLWithPath: path), leadingArguments: [])
        }
        return nil
    }

    /// Runs ExifTool with the arguments and returns standard output. Never blocks the caller's thread.
    public func run(_ arguments: [String]) async throws -> String {
        String(decoding: try await runData(arguments), as: UTF8.self)
    }

    /// Like `run`, but returns the raw bytes (for `-b` extraction of embedded images).
    public func runData(_ arguments: [String]) async throws -> Data {
        let exe = executable, args = leadingArguments + arguments
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // Read both pipes fully before waiting, so a large output cannot block the child.
                var errData = Data()
                let errGroup = DispatchGroup()
                errGroup.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errGroup.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                errGroup.wait()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    cont.resume(throwing: ExifToolError.failed(status: p.terminationStatus, stderr: String(decoding: errData, as: UTF8.self)))
                }
            }
        }
    }

    /// The camera's capture time (EXIF DateTimeOriginal plus SubSecTimeOriginal), as a naive local time.
    public func captureTime(of file: URL) async throws -> NaiveTime {
        let out = try await run(["-f", "-p", "$DateTimeOriginal|$SubSecTimeOriginal", file.path])
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let t = NaiveTime(exifDateTime: String(parts[0]), subsec: parts[1] == "-" ? nil : String(parts[1])) else {
            throw ExifToolError.unreadable("No usable capture time in \(file.lastPathComponent).")
        }
        return t
    }
}
