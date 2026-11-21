import Foundation

public enum CaptureMode: String, Sendable, CaseIterable {
    /// Raw files go to a local temporary folder for inspection.
    case exploring
    /// Raw files, with the description added, go to the destination folder.
    case capture
}

/// What was decided at the moment the shutter was pressed. Captured then, not when the file
/// arrives, so changing mode or typing a new description while a photo is still transferring
/// does not affect it.
public struct ShotContext: Sendable {
    public var mode: CaptureMode
    public var destination: URL?
    public var description: String
    /// The Mac's wall-clock time when the capture event arrived (to learn the camera's clock offset).
    public var macTime: NaiveTime

    public init(mode: CaptureMode, destination: URL?, description: String, macTime: NaiveTime = .local()) {
        self.mode = mode; self.destination = destination; self.description = description; self.macTime = macTime
    }
}

public struct DeliveryResult: Sendable {
    public var url: URL
    public var mode: CaptureMode
    /// The camera's own timestamp for the photo, if it could be read.
    public var cameraTime: NaiveTime?
    /// Set when the photo was delivered but something minor failed (e.g. the sidecar could not be written).
    public var warning: String?
}

public enum DeliveryError: Error, CustomStringConvertible {
    case noDestination
    case destinationUnavailable(URL)
    case io(String)

    public var description: String {
        switch self {
        case .noDestination: return "No destination folder is set. Choose one in Settings."
        case .destinationUnavailable(let u): return "The destination folder is not available: \(u.path)"
        case .io(let m): return m
        }
    }
}

/// Moves files from the camera's staging folder to their final place.
///
/// The SDK writes into a staging folder we own; this pipeline then routes each file. Files are
/// placed in the destination atomically (copied to a hidden temporary name in the destination
/// folder, then renamed), because other programs watch that folder and must never see a
/// half-written file. The ARW is never modified. Every delivered ARW gets a sidecar `.xmp` (with the
/// description, if any), written AFTER the ARW: the sidecar is the "this photo is complete and visible"
/// signal, and the importer waits for it. On a network share, where a big file can show up late or out
/// of order, the sidecar can therefore never be seen without its photo. If the ARW cannot be delivered,
/// the staged file is left where it is.
public actor DeliveryPipeline {
    private let exiftool: ExifTool?
    private let exploringDirectory: URL
    private var lastNumber: [String: Int] = [:]

    public init(exiftool: ExifTool?, exploringDirectory: URL) {
        self.exiftool = exiftool
        self.exploringDirectory = exploringDirectory
    }

    /// Delivers one downloaded photo according to the context captured at the shutter press.
    public func deliver(staged: URL, context: ShotContext) async throws -> DeliveryResult {
        let cameraTime = try? await exiftool?.captureTime(of: staged)
        switch context.mode {
        case .exploring:
            let stamp = (cameraTime ?? context.macTime)
            let name = "explore-\(stamp.compactDateTime)-\(stamp.exifSubsec).ARW"
            let target = try place(staged, in: exploringDirectory, named: name, createIfNeeded: true, exclusive: false)
            return DeliveryResult(url: target, mode: .exploring, cameraTime: cameraTime)

        case .capture:
            guard let dir = context.destination else { throw DeliveryError.noDestination }
            try requireUsable(dir)
            let date = (cameraTime ?? context.macTime)
            let name = reserveName(in: dir, date: date)
            let placed = try place(staged, in: dir, named: name, createIfNeeded: false, exclusive: true)
            // The photo is delivered. The sidecar goes last; a failure here must not lose or re-send the photo.
            let sidecar = XMPSidecar.url(for: placed)
            let warning = await writeSidecar(XMPSidecar.make(description: context.description), to: sidecar)
            return DeliveryResult(url: placed, mode: .capture, cameraTime: cameraTime, warning: warning)
        }
    }

    /// Copies an exploring-mode photo into the destination as a capture (the original stays in the exploring
    /// folder). Same rules as a fresh capture: atomic placement, then the sidecar with the description, last.
    public func promote(exploring file: URL, description: String, into dir: URL) async throws -> DeliveryResult {
        try requireUsable(dir)
        let cameraTime = try? await exiftool?.captureTime(of: file)
        let date = cameraTime ?? .local()
        let name = reserveName(in: dir, date: date)
        let placed = try place(file, in: dir, named: name, createIfNeeded: false, exclusive: true, keepSource: true)
        let warning = await writeSidecar(XMPSidecar.make(description: description), to: XMPSidecar.url(for: placed))
        return DeliveryResult(url: placed, mode: .capture, cameraTime: cameraTime, warning: warning)
    }

    /// Writes a black marker ARW (a stack boundary) into the destination, stamped `time` (camera clock).
    public func deliverMarker(at time: NaiveTime, into dir: URL) async throws -> URL {
        try requireUsable(dir)
        let name = reserveName(in: dir, date: time)
        let target = dir.appendingPathComponent(name)
        do {
            try writeAtomically(MarkerARW.make(at: time), to: target)
        } catch {
            throw DeliveryError.io("Could not write the marker to \(dir.path): \(error.localizedDescription)")
        }
        let sidecar = XMPSidecar.url(for: target)
        if let warning = await writeSidecar(XMPSidecar.make(description: nil, marker: true), to: sidecar) {
            throw DeliveryError.io(warning)
        }
        return target
    }

    // MARK: Naming

    /// "CAP-yyyyMMdd-NNNN.ARW": the next number after the highest already in the folder (or used this run).
    func nextName(in dir: URL, date: NaiveTime) -> String {
        let prefix = "CAP-\(date.compactDate)-"
        var highest = lastNumber[dir.path + "|" + prefix] ?? 0
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names where n.uppercased().hasPrefix(prefix) && n.uppercased().hasSuffix(".ARW") {
                let digits = n.dropFirst(prefix.count).prefix(while: \.isNumber)
                if let v = Int(digits) { highest = max(highest, v) }
            }
        }
        let next = highest + 1
        lastNumber[dir.path + "|" + prefix] = next
        return String(format: "%@%04d.ARW", prefix, next)
    }

    /// The next free "CAP-yyyyMMdd-NNNN.ARW" for which neither the ARW nor its sidecar exists yet.
    func reserveName(in dir: URL, date: NaiveTime) -> String {
        let fm = FileManager.default
        while true {
            let name = nextName(in: dir, date: date)
            let target = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: XMPSidecar.url(for: target).path) { return name }
        }
    }

    /// Writes a sidecar, retrying a few times (a network share can fail transiently). Returns a warning
    /// message on failure instead of throwing: the ARW is already in place by then.
    private func writeSidecar(_ data: Data, to url: URL) async -> String? {
        var last: Error?
        for attempt in 0..<3 {
            do { try writeAtomically(data, to: url); return nil }
            catch { last = error; if attempt < 2 { try? await Task.sleep(nanoseconds: 500_000_000) } }
        }
        return "\(url.deletingPathExtension().lastPathComponent).ARW was delivered but its sidecar could not be written (\(last?.localizedDescription ?? "unknown error")). The importer will wait for it."
    }

    /// Writes `data` to a hidden temporary file in the same folder, then renames it into place.
    private func writeAtomically(_ data: Data, to target: URL) throws {
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).partial")
        do {
            try data.write(to: partial)
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    // MARK: Placement

    private func requireUsable(_ dir: URL) throws {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            guard fm.isWritableFile(atPath: dir.path) else { throw DeliveryError.destinationUnavailable(dir) }
            return
        }
        // Create a missing folder only if its parent exists (so an unplugged drive is an error, not a fake folder).
        let parent = dir.deletingLastPathComponent()
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            throw DeliveryError.destinationUnavailable(dir)
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        catch { throw DeliveryError.destinationUnavailable(dir) }
    }

    private func place(_ src: URL, in dir: URL, named name: String, createIfNeeded: Bool, exclusive: Bool, keepSource: Bool = false) throws -> URL {
        let fm = FileManager.default
        if createIfNeeded { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let target = dir.appendingPathComponent(name)
        let partial = dir.appendingPathComponent(".\(name).partial")
        do {
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: src, to: partial)
            let final = try finalize(partial, as: target, exclusive: exclusive)
            if !keepSource { try? fm.removeItem(at: src) }
            return final
        } catch {
            try? fm.removeItem(at: partial)
            throw DeliveryError.io("Could not deliver \(src.lastPathComponent) to \(dir.path): \(error.localizedDescription)")
        }
    }

    /// Renames the hidden temporary file to its final name, never overwriting an existing file.
    /// With `exclusive` the name must be free (a sidecar has already been written for it); otherwise a
    /// numeric suffix is added.
    private func finalize(_ partial: URL, as target: URL, exclusive: Bool) throws -> URL {
        let fm = FileManager.default
        var final = target
        var n = 1
        if exclusive, fm.fileExists(atPath: target.path) {
            throw DeliveryError.io("\(target.lastPathComponent) already exists in \(target.deletingLastPathComponent().path)")
        }
        while fm.fileExists(atPath: final.path) {
            let base = target.deletingPathExtension().lastPathComponent
            final = target.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).\(target.pathExtension)")
            n += 1
        }
        try fm.moveItem(at: partial, to: final)
        return final
    }
}
