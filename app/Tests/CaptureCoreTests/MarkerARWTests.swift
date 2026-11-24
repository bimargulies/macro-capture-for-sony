import XCTest
import ImageIO
@testable import CaptureCore

final class MarkerARWTests: XCTestCase {
    var dir: URL!
    var exiftool: ExifTool!

    override func setUpWithError() throws {
        exiftool = try XCTUnwrap(ExifTool.locate(bundledResources: nil), "ExifTool is required for these tests")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("marker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeMarker(_ time: NaiveTime) throws -> URL {
        let url = dir.appendingPathComponent("marker.ARW")
        try MarkerARW.make(at: time).write(to: url)
        return url
    }

    func testExifToolReadsItAsAnArwWithTheRightMetadata() async throws {
        let t = try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 14:54:39", subsec: "050"))
        let url = try writeMarker(t)
        let out = try await exiftool.run(["-f", "-p", "$FileType|$Make|$Model|$DateTimeOriginal|$SubSecTimeOriginal|$ImageWidth", url.path])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ARW|SONY|ILCE-7RM5|2026:11:21 14:54:39|050|16")
        let read = try await exiftool.captureTime(of: url)
        XCTAssertEqual(read, t)
    }

    func testEmbeddedPreviewIsABlackJPEG() async throws {
        let url = try writeMarker(NaiveTime(seconds: 1_800_000_000))
        // Same extraction order as the importer: -PreviewImage, then -JpgFromRaw, then -OtherImage.
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        out.arguments = ["exiftool", "-b", "-PreviewImage", url.path]
        let pipe = Pipe(); out.standardOutput = pipe
        try out.run()
        let jpeg = pipe.fileHandleForReading.readDataToEndOfFile()
        out.waitUntilExit()
        XCTAssertGreaterThan(jpeg.count, 100)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        // Render to RGB and check the centre is essentially black.
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let centre = (h / 2) * w * 4 + (w / 2) * 4
        XCTAssertLessThanOrEqual(Int(px[centre]), 3)
        XCTAssertLessThanOrEqual(Int(px[centre + 1]), 3)
        XCTAssertLessThanOrEqual(Int(px[centre + 2]), 3)
    }

    func testStripDataEndsInsideTheFile() async throws {
        // The importer treats a file whose strips run past its end as "still being written".
        let url = try writeMarker(NaiveTime(seconds: 1_800_000_000))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let out = try await exiftool.run(["-s3", "-n", "-a", "-StripOffsets", "-StripByteCounts", url.path])
        let nums = out.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        XCTAssertEqual(nums.count, 2)
        XCTAssertLessThanOrEqual(nums[0] + nums[1], size)
    }

    func testExifToolReportsNoErrorsOrWarnings() async throws {
        let url = try writeMarker(NaiveTime(seconds: 1_800_000_000))
        let out = try await exiftool.run(["-a", "-s3", "-Warning", "-Error", url.path])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// Writes a sample marker for checking with other tools (the importer's own black-frame
    /// and completeness checks). Only runs when MARKER_SAMPLE_OUT is set.
    func testWriteSampleForExternalChecks() throws {
        guard let out = ProcessInfo.processInfo.environment["MARKER_SAMPLE_OUT"] else { throw XCTSkip("MARKER_SAMPLE_OUT not set") }
        let t = try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 15:00:00", subsec: "250"))
        try MarkerARW.make(at: t).write(to: URL(fileURLWithPath: out))
    }
}
