import XCTest
@testable import CaptureCore

final class StagedRecoveryTests: XCTestCase {
    private var root: URL!
    private var staging: URL!
    private var dest: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
        staging = root.appendingPathComponent("staging")
        dest = root.appendingPathComponent("dest")
        for d in [staging!, dest!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func photo(_ name: String, _ time: String) throws -> URL {
        let url = staging.appendingPathComponent(name)
        try MarkerARW.make(at: try XCTUnwrap(NaiveTime(exifDateTime: time, subsec: "000"))).write(to: url)
        return url
    }

    func testContextRoundTripsAndIsNotListedAsAPhoto() throws {
        let store = StagedRecovery(staging: staging)
        let arw = try photo("SHOT1.ARW", "2026:11:22 16:00:00")
        store.remember(ShotContext(mode: .exploring, destination: dest, description: "日本語 <&>"), for: arw)
        let back = try XCTUnwrap(store.context(for: arw))
        XCTAssertEqual(back.mode, .exploring)
        XCTAssertEqual(back.destination?.path, dest.path)
        XCTAssertEqual(back.description, "日本語 <&>")
        XCTAssertEqual(store.stagedPhotos().map(\.lastPathComponent), ["SHOT1.ARW"])
        store.forget(arw)
        XCTAssertNil(store.context(for: arw))
    }

    func testOrphanContextsAreRemovedAndLiveOnesKept() throws {
        let store = StagedRecovery(staging: staging)
        let live = try photo("LIVE.ARW", "2026:11:22 16:00:00")
        let gone = try photo("GONE.ARW", "2026:11:22 16:00:01")
        for u in [live, gone] { store.remember(ShotContext(mode: .capture, destination: dest, description: ""), for: u) }
        try FileManager.default.removeItem(at: gone)
        store.removeOrphanContexts()
        XCTAssertNotNil(store.context(for: live))
        XCTAssertNil(store.context(for: gone))
    }

    func testRemovesOnlyAbandonedCapturePartials() throws {
        for n in [".CAP-20261122-0002.ARW.partial", ".CAP-20261122-0002.xmp.partial", "CAP-20261122-0001.ARW", ".partial-123", ".DS_Store"] {
            try Data([1]).write(to: dest.appendingPathComponent(n))
        }
        XCTAssertEqual(StagedRecovery.removeAbandonedPartials(in: dest), 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        XCTAssertEqual(left, [".DS_Store", ".partial-123", "CAP-20261122-0001.ARW"])
    }

    func testPhotosAreOrderedByCameraTimeNotFileNumber() async throws {
        let tool = try XCTUnwrap(ExifTool.locate(bundledResources: nil), "ExifTool is required for this test")
        let pipeline = DeliveryPipeline(exiftool: tool, exploringDirectory: root.appendingPathComponent("exploring"))
        let late = try photo("SHOT00001.ARW", "2026:11:22 16:13:00")  // the camera's counter wrapped
        let early = try photo("SHOT09999.ARW", "2026:11:22 16:11:00")
        let ordered = await pipeline.inCaptureOrder([late, early])
        XCTAssertEqual(ordered.map(\.lastPathComponent), ["SHOT09999.ARW", "SHOT00001.ARW"])
    }
}
