import XCTest
@testable import CaptureCore

final class NaiveTimeTests: XCTestCase {
    func testParsesAndFormatsExifTime() throws {
        let t = try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 14:54:39", subsec: "212"))
        XCTAssertEqual(t.exifDateTime, "2026:11:21 14:54:39")
        XCTAssertEqual(t.exifSubsec, "212")
        XCTAssertEqual(t.compactDate, "20261121")
        XCTAssertEqual(t.compactDateTime, "20261121-145439")
    }

    func testSubsecKeepsLeadingZerosAndShortForms() throws {
        XCTAssertEqual(try XCTUnwrap(NaiveTime(exifDateTime: "2026:01:02 03:04:05", subsec: "050")).exifSubsec, "050")
        XCTAssertEqual(try XCTUnwrap(NaiveTime(exifDateTime: "2026:01:02 03:04:05", subsec: "5")).exifSubsec, "500")
        XCTAssertEqual(try XCTUnwrap(NaiveTime(exifDateTime: "2026:01:02 03:04:05", subsec: nil)).exifSubsec, "000")
    }

    func testRejectsGarbage() {
        XCTAssertNil(NaiveTime(exifDateTime: "nope"))
        XCTAssertNil(NaiveTime(exifDateTime: "2026:11:21"))
    }

    func testOrderingIncludesFractions() throws {
        let a = try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 14:54:39", subsec: "212"))
        let b = try XCTUnwrap(NaiveTime(exifDateTime: "2026:11:21 14:54:39", subsec: "213"))
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(a, a.advanced(by: 0.001 * 5))
    }

    func testLocalTimeUsesTheZone() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = NaiveTime.local(from: date, in: TimeZone(secondsFromGMT: 0)!)
        let plus1 = NaiveTime.local(from: date, in: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertEqual(plus1.seconds - utc.seconds, 3600)
    }
}
