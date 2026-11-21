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
}
