import Foundation

/// Formats raw Sony SDK exposure values for display (encodings per the SDK's RemoteCli sample).
public enum ExposureText {
    /// F-number: value is 100 x f ("F5.6", "F8"). 0 or 0xFFFF = unknown.
    public static func aperture(_ v: UInt64) -> String? {
        let f = UInt16(truncatingIfNeeded: v)
        if f == 0 || f == 0xFFFF { return nil }
        return f % 100 == 0 ? "F\(f / 100)" : String(format: "F%.1f", Double(f) / 100)
    }

    /// Shutter speed: high 16 bits numerator, low 16 bits denominator ("1/250", "0.8\"", "2\""). 0 = bulb.
    public static func shutter(_ v: UInt64) -> String? {
        let raw = UInt32(truncatingIfNeeded: v)
        if raw == 0 { return "Bulb" }
        if raw == 0xFFFFFFFF { return nil }
        let num = raw >> 16, den = raw & 0xFFFF
        if den == 0 { return nil }
        if num == 1 { return "1/\(den)" }
        if num % den == 0 { return "\(num / den)\"" }
        return String(format: "%.1f\"", Double(num) / Double(den))
    }

    /// ISO: low 24 bits the value, 0xFFFFFF = auto; bits 24-27 are a noise-reduction mode, 28-31 an extended flag.
    public static func iso(_ v: UInt64) -> String? {
        let raw = UInt32(truncatingIfNeeded: v)
        let value = raw & 0x00FFFFFF
        if raw == 0xFFFFFFFF { return nil }
        return value == 0x00FFFFFF ? "ISO Auto" : "ISO \(value)"
    }

    /// Signed EV in thousandths (exposure compensation): "+0.7", "-1.3", "0.0".
    public static func ev(_ v: UInt64) -> String {
        let t = Double(Int16(truncatingIfNeeded: v)) / 1000
        if abs(t) < 0.05 { return "0.0" }
        return String(format: "%+.1f", t)
    }
}
