import Foundation

/// Lets photos left in the staging folder (the app quit or crashed before delivering them) be delivered at the
/// next launch. What was decided at the shutter press is kept in a small hidden file beside each staged photo.
public struct StagedRecovery: Sendable {
    public let staging: URL

    public init(staging: URL) { self.staging = staging }

    private struct Record: Codable {
        var mode: String
        var destination: String?
        var description: String
    }

    private func contextURL(for arw: URL) -> URL {
        staging.appendingPathComponent(".\(arw.lastPathComponent).context.json")
    }

    /// Photos waiting in the staging folder, in no particular order.
    public func stagedPhotos() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.uppercased().hasSuffix(".ARW") }
            .sorted().map { staging.appendingPathComponent($0) }
    }

    public func remember(_ context: ShotContext, for arw: URL) {
        let record = Record(mode: context.mode.rawValue, destination: context.destination?.path, description: context.description)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: contextURL(for: arw), options: .atomic)
    }

    /// The context saved for a staged photo, or nil if there is none or it cannot be read.
    public func context(for arw: URL) -> ShotContext? {
        guard let data = try? Data(contentsOf: contextURL(for: arw)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let mode = CaptureMode(rawValue: record.mode) else { return nil }
        return ShotContext(mode: mode, destination: record.destination.map { URL(fileURLWithPath: $0, isDirectory: true) },
                           description: record.description)
    }

    public func forget(_ arw: URL) {
        try? FileManager.default.removeItem(at: contextURL(for: arw))
    }

    /// Removes saved contexts whose photo is gone.
    public func removeOrphanContexts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        let photos = Set(stagedPhotos().map(\.lastPathComponent))
        for name in names where name.hasPrefix(".") && name.hasSuffix(".context.json") {
            let photo = String(name.dropFirst().dropLast(".context.json".count))
            if !photos.contains(photo) { try? FileManager.default.removeItem(at: staging.appendingPathComponent(name)) }
        }
    }

    /// Deletes hidden half-written `CAP-` files left in a destination by an interrupted delivery. Their sources are
    /// still in staging. Only safe at launch, when no delivery is running. Returns how many were removed.
    @discardableResult
    public static func removeAbandonedPartials(in dir: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(".CAP-") && name.hasSuffix(".partial") {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}

extension DeliveryPipeline {
    /// Sorts staged photos by the camera's capture time (file numbers can wrap); unreadable ones go last, by name.
    public func inCaptureOrder(_ files: [URL]) async -> [URL] {
        var timed: [(url: URL, time: NaiveTime?)] = []
        for url in files { timed.append((url, await captureTime(of: url))) }
        return timed.sorted { a, b in
            switch (a.time, b.time) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.url.lastPathComponent < b.url.lastPathComponent
            }
        }.map(\.url)
    }
}
