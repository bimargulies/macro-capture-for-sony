import XCTest
@testable import CaptureCore

final class XMPSidecarTests: XCTestCase {
    func testSidecarNameReplacesTheExtension() {
        XCTAssertEqual(XMPSidecar.url(for: URL(fileURLWithPath: "/x/CAP-20261121-0001.ARW")).path, "/x/CAP-20261121-0001.xmp")
    }

    func testPacketIsWellFormedXml() throws {
        let data = XMPSidecar.make(description: "a < b & \"c\"")
        let parser = XMLParser(data: data)
        XCTAssertTrue(parser.parse(), "XML error: \(String(describing: parser.parserError))")
    }

    func testDescriptionIsOneCleanLine() {
        XCTAssertEqual(XMPSidecar.clean("  line one\nline two\t\u{0001}end  "), "line one line two end")
        XCTAssertEqual(XMPSidecar.escape("<&>\"'"), "&lt;&amp;&gt;&quot;&apos;")
    }

    func testPacketStartsWithTheXmpMarkerAndEndsWithTheTrailer() {
        let text = String(decoding: XMPSidecar.make(description: "x"), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xpacket begin="))
        XCTAssertTrue(text.contains("<dc:description>"))
        XCTAssertTrue(text.contains("xml:lang=\"x-default\">x</rdf:li>"))
        XCTAssertTrue(text.contains("<?xpacket end=\"w\"?>"))
    }

    /// Writes a sample sidecar for checking with other tools (the importer). Only runs when SIDECAR_SAMPLE_OUT is set.
    func testWriteSampleForExternalChecks() throws {
        guard let out = ProcessInfo.processInfo.environment["SIDECAR_SAMPLE_OUT"] else { throw XCTSkip("SIDECAR_SAMPLE_OUT not set") }
        try XMPSidecar.make(description: "Zeiss 50mm – café <stack> & \"widget\" 日本").write(to: URL(fileURLWithPath: out))
    }

    func testEmptyDescriptionOmitsTheElementAndMarkerAddsTheKeyword() {
        let plain = String(decoding: XMPSidecar.make(description: nil), as: UTF8.self)
        XCTAssertFalse(plain.contains("dc:description"))
        XCTAssertFalse(plain.contains(XMPSidecar.markerKeyword))
        XCTAssertTrue(XMLParser(data: XMPSidecar.make(description: "   ")).parse())
        let marker = String(decoding: XMPSidecar.make(description: nil, marker: true), as: UTF8.self)
        XCTAssertTrue(marker.contains("<rdf:li>\(XMPSidecar.markerKeyword)</rdf:li>"))
        XCTAssertTrue(XMLParser(data: XMPSidecar.make(description: "x", marker: true)).parse())
    }

    /// Writes plain / described / marker sidecars for checking with the importer. Only runs when SIDECAR_SAMPLES_DIR is set.
    func testWriteSamplesForTheImporter() throws {
        guard let dir = ProcessInfo.processInfo.environment["SIDECAR_SAMPLES_DIR"] else { throw XCTSkip("SIDECAR_SAMPLES_DIR not set") }
        let d = URL(fileURLWithPath: dir)
        try XMPSidecar.make(description: nil).write(to: d.appendingPathComponent("plain.xmp"))
        try XMPSidecar.make(description: "stack B: café <1> & 日本").write(to: d.appendingPathComponent("described.xmp"))
        try XMPSidecar.make(description: nil, marker: true).write(to: d.appendingPathComponent("marker.xmp"))
    }
}
