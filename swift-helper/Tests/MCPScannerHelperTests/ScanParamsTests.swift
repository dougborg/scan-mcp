import XCTest
@testable import mcp_scanner_helper

final class ScanParamsTests: XCTestCase {

    func testDecodeMinimalJSON() throws {
        let json = "{}"
        let params = try JSONDecoder().decode(ScanParams.self, from: Data(json.utf8))
        XCTAssertNil(params.device_id)
        XCTAssertNil(params.resolution_dpi)
        XCTAssertNil(params.source)
    }

    func testDecodeFullJSON() throws {
        let json = """
        {
            "device_id": "ABC-123",
            "resolution_dpi": 300,
            "color_mode": "Color",
            "source": "ADF Duplex",
            "duplex": true,
            "page_size": "Letter",
            "custom_size_mm": {"width": 210.0, "height": 297.0},
            "output_format": "pdf-searchable",
            "ocr": true,
            "autoname": false,
            "summarize": true
        }
        """
        let params = try JSONDecoder().decode(ScanParams.self, from: Data(json.utf8))
        XCTAssertEqual(params.device_id, "ABC-123")
        XCTAssertEqual(params.resolution_dpi, 300)
        XCTAssertEqual(params.color_mode, "Color")
        XCTAssertEqual(params.source, "ADF Duplex")
        XCTAssertEqual(params.duplex, true)
        XCTAssertEqual(params.page_size, "Letter")
        XCTAssertEqual(params.custom_size_mm?.width, 210.0)
        XCTAssertEqual(params.custom_size_mm?.height, 297.0)
        XCTAssertEqual(params.output_format, "pdf-searchable")
        XCTAssertEqual(params.ocr, true)
        XCTAssertEqual(params.autoname, false)
        XCTAssertEqual(params.summarize, true)
    }

    func testRoundTripPreservesFields() throws {
        var original = ScanParams()
        original.device_id = "round-trip"
        original.resolution_dpi = 600
        original.source = "ADF"
        original.output_format = "pdf"

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScanParams.self, from: encoded)

        XCTAssertEqual(decoded.device_id, original.device_id)
        XCTAssertEqual(decoded.resolution_dpi, original.resolution_dpi)
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.output_format, original.output_format)
    }

    func testIgnoresUnknownFields() throws {
        // Defensive: the TS side might add fields we don't yet know about.
        let json = """
        {"device_id": "x", "future_field": "ignored", "another": [1, 2]}
        """
        XCTAssertNoThrow(
            try JSONDecoder().decode(ScanParams.self, from: Data(json.utf8))
        )
    }
}
