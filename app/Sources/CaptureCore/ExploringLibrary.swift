import CoreGraphics
import Foundation
import ImageIO

/// The folder of exploring-mode photos, kept to the most recent few, plus the small image caches
/// (thumbnail, full-size preview) derived from them. The ARWs themselves are never modified.
public struct ExploringLibrary: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public var cacheDirectory: URL { directory.appendingPathComponent(".cache") }

    /// Exploring ARWs, oldest first (their names embed the camera time, so name order is time order).
    public func items() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("explore-") && $0.uppercased().hasSuffix(".ARW") }
            .sorted().map { directory.appendingPathComponent($0) }
    }

    public func thumbnailURL(for arw: URL) -> URL { cacheDirectory.appendingPathComponent(arw.deletingPathExtension().lastPathComponent + ".thumb.jpg") }
    public func fullURL(for arw: URL) -> URL { cacheDirectory.appendingPathComponent(arw.deletingPathExtension().lastPathComponent + ".full.jpg") }
    public func infoURL(for arw: URL) -> URL { cacheDirectory.appendingPathComponent(arw.deletingPathExtension().lastPathComponent + ".orientation") }

    /// Removes the thumbnail, preview and orientation files derived from a photo.
    public func removeCaches(for arw: URL) {
        for url in [thumbnailURL(for: arw), fullURL(for: arw), infoURL(for: arw)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes all but the newest `keep` photos, with their caches, and any cache files left without a photo.
    public func prune(keep: Int) {
        let fm = FileManager.default
        let all = items()
        for url in all.dropLast(max(keep, 0)) { try? fm.removeItem(at: url) }
        let live = Set(items().map { $0.deletingPathExtension().lastPathComponent })
        for name in (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [] {
            let stem = name.components(separatedBy: ".").first ?? name
            if !live.contains(stem) { try? fm.removeItem(at: cacheDirectory.appendingPathComponent(name)) }
        }
    }
}

/// Pulls the camera's embedded JPEGs out of an ARW (read-only, via ExifTool) and caches them.
public actor ARWPreviews {
    private let exiftool: ExifTool
    private let library: ExploringLibrary

    public init(exiftool: ExifTool, library: ExploringLibrary) { self.exiftool = exiftool; self.library = library }

    /// EXIF orientation of the photo (1, 3, 6 or 8; anything else is treated as 1).
    public func orientation(of arw: URL) async -> Int {
        let info = library.infoURL(for: arw)
        if let s = try? String(contentsOf: info, encoding: .utf8), let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
        let out = (try? await exiftool.run(["-s3", "-n", "-Orientation", arw.path])) ?? ""
        let v = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        let o = [1, 3, 6, 8].contains(v) ? v : 1
        try? FileManager.default.createDirectory(at: library.cacheDirectory, withIntermediateDirectories: true)
        try? "\(o)".write(to: info, atomically: true, encoding: .utf8)
        return o
    }

    /// A small, already-rotated JPEG for the carousel.
    public func thumbnail(for arw: URL) async throws -> URL {
        let target = library.thumbnailURL(for: arw)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let data = try await exiftool.runData(["-b", "-PreviewImage", arw.path])
        let turns = await orientation(of: arw)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)
        else { throw ExifToolError.unreadable("No preview image in \(arw.lastPathComponent).") }
        let rotated = ExploringLibrary.rotate(small, orientation: turns)
        try FileManager.default.createDirectory(at: library.cacheDirectory, withIntermediateDirectories: true)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { throw ExifToolError.unreadable("JPEG encoder unavailable") }
        CGImageDestinationAddImage(dest, rotated, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExifToolError.unreadable("Could not write thumbnail") }
        try (out as Data).write(to: target, options: .atomic)
        return target
    }

    /// The full-resolution JPEG the camera embeds (unrotated), and the orientation to display it with.
    public func full(for arw: URL) async throws -> (url: URL, orientation: Int) {
        let target = library.fullURL(for: arw)
        let turns = await orientation(of: arw)
        if FileManager.default.fileExists(atPath: target.path) { return (target, turns) }
        let data = try await exiftool.runData(["-b", "-JpgFromRaw", arw.path])
        guard data.count > 1000 else { throw ExifToolError.unreadable("No full-size preview in \(arw.lastPathComponent).") }
        try FileManager.default.createDirectory(at: library.cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return (target, turns)
    }
}

extension ExploringLibrary {
    /// Rotates an image for EXIF orientation 3 (180°), 6 (90° clockwise) or 8 (90° counter-clockwise).
    public static func rotate(_ image: CGImage, orientation: Int) -> CGImage {
        let w = image.width, h = image.height
        guard [3, 6, 8].contains(orientation) else { return image }
        let swap = orientation != 3
        guard let ctx = CGContext(data: nil, width: swap ? h : w, height: swap ? w : h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        switch orientation {
        case 6: ctx.translateBy(x: 0, y: CGFloat(w)); ctx.rotate(by: -.pi / 2)
        case 8: ctx.translateBy(x: CGFloat(h), y: 0); ctx.rotate(by: .pi / 2)
        default: ctx.translateBy(x: CGFloat(w), y: CGFloat(h)); ctx.rotate(by: .pi)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
