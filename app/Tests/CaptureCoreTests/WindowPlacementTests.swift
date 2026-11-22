import XCTest
@testable import CaptureCore

final class WindowPlacementTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let side = CGRect(x: -800, y: -324, width: 800, height: 1280)
    private let onSide = CGRect(x: -773, y: 187, width: 763, height: 739)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "WindowPlacementTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testRestoresTheSavedFrame() {
        let p = WindowPlacement(defaults: defaults)
        XCTAssertNil(p.frame(screens: [laptop, side]))
        p.save(onSide, screens: [laptop, side])
        XCTAssertEqual(p.frame(screens: [laptop, side]), onSide)
    }

    func testScreenOrderDoesNotMatter() {
        let p = WindowPlacement(defaults: defaults)
        p.save(onSide, screens: [laptop, side])
        XCTAssertEqual(p.frame(screens: [side, laptop]), onSide)
    }

    func testEachLayoutKeepsItsOwnFrame() {
        let p = WindowPlacement(defaults: defaults)
        let onLaptop = CGRect(x: 100, y: 100, width: 763, height: 739)
        p.save(onSide, screens: [laptop, side])
        XCTAssertNil(p.frame(screens: [laptop]))  // monitor unplugged: no position to use yet
        p.save(onLaptop, screens: [laptop])       // macOS moved the window to the laptop
        XCTAssertEqual(p.frame(screens: [laptop, side]), onSide)
        XCTAssertEqual(p.frame(screens: [laptop]), onLaptop)
    }

    func testRejectsAFrameWhoseTitleBarIsOffScreen() {
        let p = WindowPlacement(defaults: defaults)
        p.save(CGRect(x: 5000, y: 5000, width: 763, height: 739), screens: [laptop])
        XCTAssertNil(p.frame(screens: [laptop]))
    }
}
