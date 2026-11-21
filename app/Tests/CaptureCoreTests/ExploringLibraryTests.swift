import XCTest
@testable import CaptureCore

final class ExploringLibraryTests: XCTestCase {
    func makeDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testItemsAreOldestFirstAndOnlyExploringArws() throws {
        let d = try makeDir()
        for n in ["explore-20261121-120000-000.ARW", "explore-20261121-110000-000.ARW", "CAP-1.ARW", "notes.txt"] {
            try Data([1]).write(to: d.appendingPathComponent(n))
        }
        let names = ExploringLibrary(directory: d).items().map(\.lastPathComponent)
        XCTAssertEqual(names, ["explore-20261121-110000-000.ARW", "explore-20261121-120000-000.ARW"])
    }

    func testPruneKeepsNewestAndDeletesTheirCaches() throws {
        let d = try makeDir()
        let lib = ExploringLibrary(directory: d)
        try FileManager.default.createDirectory(at: lib.cacheDirectory, withIntermediateDirectories: true)
        let names = (1...5).map { "explore-20261121-12000\($0)-000.ARW" }
        for n in names {
            let u = d.appendingPathComponent(n)
            try Data([1]).write(to: u)
            try Data([1]).write(to: lib.thumbnailURL(for: u))
            try Data([1]).write(to: lib.fullURL(for: u))
        }
        lib.prune(keep: 2)
        XCTAssertEqual(lib.items().map(\.lastPathComponent), Array(names.suffix(2)))
        let cache = try FileManager.default.contentsOfDirectory(atPath: lib.cacheDirectory.path)
        XCTAssertEqual(cache.count, 4)  // thumb + full for each of the two survivors
    }

    func testPromoteCopiesWithSidecarAndKeepsTheOriginal() async throws {
        let d = try makeDir(), dest = try makeDir()
        let src = d.appendingPathComponent("explore-20261121-120000-000.ARW")
        try MarkerARW.make(at: NaiveTime(exifDateTime: "2026:11:21 12:00:00", subsec: "000")!).write(to: src)
        let pipeline = DeliveryPipeline(exiftool: ExifTool.locate(bundledResources: nil), exploringDirectory: d)
        let r = try await pipeline.promote(exploring: src, description: "hello", into: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.url.path))
        XCTAssertTrue(r.url.lastPathComponent.hasPrefix("CAP-"))
        let xmp = try String(contentsOf: XMPSidecar.url(for: r.url))
        XCTAssertTrue(xmp.contains("hello"))
        XCTAssertNil(r.warning)
    }
}
