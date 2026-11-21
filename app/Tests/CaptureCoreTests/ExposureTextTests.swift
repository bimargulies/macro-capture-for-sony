import XCTest
@testable import CaptureCore

final class ExposureTextTests: XCTestCase {
    func testAperture() {
        XCTAssertEqual(ExposureText.aperture(800), "F8")
        XCTAssertEqual(ExposureText.aperture(560), "F5.6")
        XCTAssertNil(ExposureText.aperture(0))
    }
    func testShutter() {
        XCTAssertEqual(ExposureText.shutter(0x00010FA0), "1/4000")
        XCTAssertEqual(ExposureText.shutter(0x00020001), "2\"")
        XCTAssertEqual(ExposureText.shutter(0x0008000A), "0.8\"")
        XCTAssertEqual(ExposureText.shutter(0), "Bulb")
    }
    func testISO() {
        XCTAssertEqual(ExposureText.iso(400), "ISO 400")
        XCTAssertEqual(ExposureText.iso(0x00FFFFFF), "ISO Auto")
        XCTAssertEqual(ExposureText.iso(0x10000064), "ISO 100")
    }
    func testEV() {
        XCTAssertEqual(ExposureText.ev(700), "+0.7")
        XCTAssertEqual(ExposureText.ev(UInt64(UInt16(bitPattern: -1300))), "-1.3")
        XCTAssertEqual(ExposureText.ev(0), "0.0")
    }
}
