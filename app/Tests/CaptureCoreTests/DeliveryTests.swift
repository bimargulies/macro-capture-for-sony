import XCTest
@testable import CaptureCore

final class DeliveryTests: XCTestCase {
    var root: URL!
    var staging: URL!, exploring: URL!, dest: URL!
    var exiftool: ExifTool!
    var pipeline: DeliveryPipeline!

    override func setUpWithError() throws {
        exiftool = try XCTUnwrap(ExifTool.locate(bundledResources: nil), "ExifTool is required for these tests")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-tests-\(UUID().uuidString)")
        staging = root.appendingPathComponent("staging")
        exploring = root.appendingPathComponent("exploring")
        dest = root.appendingPathComponent("dest")
        for d in [staging!, dest!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        pipeline = DeliveryPipeline(exiftool: exiftool, exploringDirectory: exploring)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A stand-in for a downloaded photo: a marker ARW with a known camera time.
    private func stagedPhoto(_ name: String = "SHOT00001.ARW", time: String = "2026:11:21 14:54:39", subsec: String = "212") throws -> URL {
        let url = staging.appendingPathComponent(name)
        let t = try XCTUnwrap(NaiveTime(exifDateTime: time, subsec: subsec))
        try MarkerARW.make(at: t).write(to: url)
        return url
    }
    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testExploringKeepsTheFileLocallyAndRemovesTheStagedCopy() async throws {
        let src = try stagedPhoto()
        let original = try Data(contentsOf: src)
        let r = try await pipeline.deliver(staged: src, context: ShotContext(mode: .exploring, destination: dest, description: "ignored"))
        XCTAssertEqual(r.mode, .exploring)
        XCTAssertEqual(r.url.lastPathComponent, "explore-20261121-145439-212.ARW")
        XCTAssertEqual(r.url.deletingLastPathComponent().standardizedFileURL, exploring.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try names(dest), [], "nothing is delivered to the destination in exploring mode")
        XCTAssertEqual(try Data(contentsOf: r.url), original, "the ARW is never modified")
        XCTAssertEqual(try names(exploring), [r.url.lastPathComponent], "no sidecar in exploring mode")
    }

    private func sidecarDescription(_ url: URL) async throws -> String {
        try await exiftool.run(["-s3", "-XMP-dc:Description", url.path]).trimmingCharacters(in: .newlines)
    }

    func testCapturePlacesTheUntouchedArwWithADescriptionSidecar() async throws {
        let src = try stagedPhoto()
        let original = try Data(contentsOf: src)
        let r = try await pipeline.deliver(staged: src, context: ShotContext(mode: .capture, destination: dest, description: "widget, stack 2"))
        XCTAssertEqual(r.url.lastPathComponent, "CAP-20261121-0001.ARW")
        XCTAssertEqual(r.cameraTime?.exifDateTime, "2026:11:21 14:54:39")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try Data(contentsOf: r.url), original, "the ARW must be byte-identical to what the camera made")
        let sidecar = XMPSidecar.url(for: r.url)
        XCTAssertEqual(sidecar.lastPathComponent, "CAP-20261121-0001.xmp")
        let description1 = try await sidecarDescription(sidecar)
        XCTAssertEqual(description1, "widget, stack 2")
        XCTAssertEqual(try names(dest), ["CAP-20261121-0001.ARW", "CAP-20261121-0001.xmp"], "no partial files are left behind")
    }

    func testNonAsciiAndXmlSpecialCharactersSurvive() async throws {
        for text in ["café – naïve 日本", "a < b & c > \"d\" 'e'"] {
            let r = try await pipeline.deliver(staged: try stagedPhoto(), context: ShotContext(mode: .capture, destination: dest, description: text))
            let description2 = try await sidecarDescription(XMPSidecar.url(for: r.url))
            XCTAssertEqual(description2, text)
        }
    }

    func testEmptyDescriptionStillWritesAnEmptySidecar() async throws {
        let src = try stagedPhoto()
        let original = try Data(contentsOf: src)
        let r = try await pipeline.deliver(staged: src, context: ShotContext(mode: .capture, destination: dest, description: "   "))
        XCTAssertEqual(try Data(contentsOf: r.url), original)
        let sidecar = XMPSidecar.url(for: r.url)
        XCTAssertEqual(try names(dest), [r.url.lastPathComponent, sidecar.lastPathComponent], "a sidecar is always written: it signals the photo is complete")
        let subject = try await exiftool.run(["-s3", "-XMP-dc:Description", "-XMP-dc:Subject", sidecar.path])
        XCTAssertEqual(subject.trimmingCharacters(in: .whitespacesAndNewlines), "", "no description and not a marker")
    }

    func testAStraySidecarMakesThePipelineSkipThatNumber() async throws {
        try XMPSidecar.make(description: "old").write(to: dest.appendingPathComponent("CAP-20261121-0001.xmp"))
        let r = try await pipeline.deliver(staged: try stagedPhoto(), context: ShotContext(mode: .capture, destination: dest, description: "new"))
        XCTAssertEqual(r.url.lastPathComponent, "CAP-20261121-0002.ARW")
        let description3 = try await sidecarDescription(dest.appendingPathComponent("CAP-20261121-0001.xmp"))
        XCTAssertEqual(description3, "old", "an existing sidecar is never overwritten")
        let description4 = try await sidecarDescription(XMPSidecar.url(for: r.url))
        XCTAssertEqual(description4, "new")
    }

    func testNumberingContinuesAcrossPhotosAndMarkers() async throws {
        let a = try await pipeline.deliver(staged: try stagedPhoto("A.ARW"), context: ShotContext(mode: .capture, destination: dest, description: ""))
        let markerURL = try await pipeline.deliverMarker(at: try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 14:55:00")), into: dest)
        let b = try await pipeline.deliver(staged: try stagedPhoto("B.ARW"), context: ShotContext(mode: .capture, destination: dest, description: ""))
        XCTAssertEqual([a.url, markerURL, b.url].map(\.lastPathComponent),
                       ["CAP-20261121-0001.ARW", "CAP-20261121-0002.ARW", "CAP-20261121-0003.ARW"])
        // A fresh pipeline (e.g. after a restart) continues after what is already in the folder.
        let fresh = DeliveryPipeline(exiftool: exiftool, exploringDirectory: exploring)
        let c = try await fresh.deliver(staged: try stagedPhoto("C.ARW"), context: ShotContext(mode: .capture, destination: dest, description: ""))
        XCTAssertEqual(c.url.lastPathComponent, "CAP-20261121-0004.ARW")
    }

    func testMarkerIsAValidBlackFrameStampedWithTheGivenTime() async throws {
        let t = try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 15:00:01", subsec: "500"))
        let url = try await pipeline.deliverMarker(at: t, into: dest)
        let read = try await exiftool.captureTime(of: url)
        XCTAssertEqual(read, t)
        XCTAssertEqual(try names(dest), [url.lastPathComponent, XMPSidecar.url(for: url).lastPathComponent])
        let subject = try await exiftool.run(["-s3", "-XMP-dc:Subject", XMPSidecar.url(for: url).path])
        XCTAssertEqual(subject.trimmingCharacters(in: .whitespacesAndNewlines), XMPSidecar.markerKeyword, "the sidecar says it is a marker")
    }

    func testMissingDestinationFailsAndKeepsTheStagedFile() async throws {
        let src = try stagedPhoto()
        let gone = root.appendingPathComponent("not-mounted/Capture")  // parent does not exist
        do {
            _ = try await pipeline.deliver(staged: src, context: ShotContext(mode: .capture, destination: gone, description: ""))
            XCTFail("expected an error")
        } catch let e as DeliveryError {
            guard case .destinationUnavailable = e else { return XCTFail("wrong error: \(e)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the staged file must not be lost")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path), "no fake folder is created")
    }

    func testNoDestinationIsReported() async throws {
        let src = try stagedPhoto()
        do {
            _ = try await pipeline.deliver(staged: src, context: ShotContext(mode: .capture, destination: nil, description: ""))
            XCTFail("expected an error")
        } catch let e as DeliveryError {
            guard case .noDestination = e else { return XCTFail("wrong error: \(e)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testAMissingLeafFolderIsCreatedWhenItsParentExists() async throws {
        let leaf = dest.appendingPathComponent("Capture")
        let r = try await pipeline.deliver(staged: try stagedPhoto(), context: ShotContext(mode: .capture, destination: leaf, description: ""))
        XCTAssertEqual(r.url.deletingLastPathComponent().standardizedFileURL, leaf.standardizedFileURL)
    }
}
