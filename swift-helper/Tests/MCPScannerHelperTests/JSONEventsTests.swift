import XCTest
@testable import mcp_scanner_helper

/// The JSON event format is the wire contract with scan-mcp (Node). Lock down
/// the shape so changes are intentional, not accidental.
final class JSONEventsTests: XCTestCase {

    private func decode(_ event: ScanEvent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testStageEventShape() throws {
        let evt = ScanEvent.stage("scanning")
        let dict = try decode(evt)
        XCTAssertEqual(dict["type"] as? String, "stage")
        XCTAssertEqual(dict["stage"] as? String, "scanning")
        XCTAssertNotNil(dict["timestamp"] as? String, "timestamp must be present and be a string")
    }

    func testPageScannedEventShape() throws {
        let evt = ScanEvent.pageScanned(index: 3, path: "/tmp/test/page_0003.tiff")
        let dict = try decode(evt)
        XCTAssertEqual(dict["type"] as? String, "page_scanned")
        XCTAssertEqual(dict["index"] as? Int, 3)
        XCTAssertEqual(dict["path"] as? String, "/tmp/test/page_0003.tiff")
        XCTAssertNotNil(dict["timestamp"] as? String)
    }

    func testWarningEventShape() throws {
        let evt = ScanEvent.warning("ICA returned unexpected result")
        let dict = try decode(evt)
        XCTAssertEqual(dict["type"] as? String, "warning")
        XCTAssertEqual(dict["message"] as? String, "ICA returned unexpected result")
    }

    func testErrorEventShape() throws {
        let evt = ScanEvent.error("boom")
        let dict = try decode(evt)
        XCTAssertEqual(dict["type"] as? String, "error")
        XCTAssertEqual(dict["message"] as? String, "boom")
    }

    func testTimestampIsISO8601() throws {
        let evt = ScanEvent.stage("opening_session")
        let dict = try decode(evt)
        guard let ts = dict["timestamp"] as? String else {
            XCTFail("missing timestamp")
            return
        }
        // ISO8601: 2026-05-22T16:00:00Z
        XCTAssertTrue(ts.contains("T"), "timestamp should be ISO8601: \(ts)")
        XCTAssertTrue(ts.hasSuffix("Z"), "timestamp should be UTC (suffix Z): \(ts)")
    }
}
