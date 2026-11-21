import Foundation

/// A wall-clock time with no time zone, like the timestamps in EXIF. The camera's clock and
/// the Mac's clock can differ (different zone or DST setting), so we keep both as naive local
/// times and work with the difference between them.
public struct NaiveTime: Comparable, Hashable, Sendable {
    /// Milliseconds since 1970-01-01 00:00:00, treating the wall-clock components as if they were UTC.
    /// (Integer milliseconds, so EXIF sub-second values round-trip exactly.)
    public let milliseconds: Int64

    public init(milliseconds: Int64) { self.milliseconds = milliseconds }
    public init(seconds: Double) { self.milliseconds = Int64((seconds * 1000).rounded()) }

    public var seconds: Double { Double(milliseconds) / 1000 }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Parses "2026:11:21 14:54:39" with an optional EXIF SubSecTime string ("212" = 0.212 s, "5" = 0.5 s).
    public init?(exifDateTime: String, subsec: String? = nil) {
        let parts = exifDateTime.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let d = parts[0].split(separator: ":").compactMap { Int($0) }
        let t = parts[1].split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 3 else { return nil }
        var dc = DateComponents()
        dc.year = d[0]; dc.month = d[1]; dc.day = d[2]
        dc.hour = t[0]; dc.minute = t[1]; dc.second = t[2]
        guard let date = NaiveTime.utc.date(from: dc) else { return nil }
        var ms = Int64(date.timeIntervalSince1970.rounded()) * 1000
        if let sub = subsec?.trimmingCharacters(in: .whitespaces), !sub.isEmpty, sub.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let three = String(sub.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            ms += Int64(three) ?? 0
        }
        self.milliseconds = ms
    }

    /// The Mac's current local wall-clock time.
    public static func local(from date: Date = Date(), in zone: TimeZone = .current) -> NaiveTime {
        NaiveTime(seconds: date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date)))
    }

    private var wholeSecond: Date {
        let whole = milliseconds >= 0 ? milliseconds / 1000 : -((-milliseconds + 999) / 1000)
        return Date(timeIntervalSince1970: Double(whole))
    }

    /// "2026:11:21 14:54:39" (EXIF DateTimeOriginal format).
    public var exifDateTime: String {
        let c = NaiveTime.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wholeSecond)
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// Three-digit milliseconds, as written to EXIF SubSecTimeOriginal ("212").
    public var exifSubsec: String {
        String(format: "%03d", Int(((milliseconds % 1000) + 1000) % 1000))
    }

    /// "20261121", for file names.
    public var compactDate: String {
        let c = NaiveTime.utc.dateComponents([.year, .month, .day], from: wholeSecond)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }

    /// "20261121-145439", for file names.
    public var compactDateTime: String {
        let c = NaiveTime.utc.dateComponents([.hour, .minute, .second], from: wholeSecond)
        return compactDate + String(format: "-%02d%02d%02d", c.hour!, c.minute!, c.second!)
    }

    public func advanced(by delta: Double) -> NaiveTime {
        NaiveTime(milliseconds: milliseconds + Int64((delta * 1000).rounded()))
    }
    public static func < (a: NaiveTime, b: NaiveTime) -> Bool { a.milliseconds < b.milliseconds }
}
