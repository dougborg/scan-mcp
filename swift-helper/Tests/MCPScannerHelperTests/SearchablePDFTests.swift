import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import mcp_scanner_helper

/// Full-pipeline tests for SearchablePDF: render text into a TIFF, run it through
/// SearchablePDF.assemble() with `searchable: true`, then verify the produced PDF
/// has selectable/searchable text via PDFKit.
///
/// These exercise the OCR → invisible-text-layer → PDF extraction round-trip
/// without requiring a scanner.
final class SearchablePDFTests: XCTestCase {

    /// Render a CGImage containing the given text at a known DPI, save as TIFF, return the URL.
    private func makeTIFF(text: String, dpi: CGFloat = 200) throws -> URL {
        let widthIn: CGFloat = 4.0
        let heightIn: CGFloat = 1.5
        let widthPx = Int(widthIn * dpi)
        let heightPx = Int(heightIn * dpi)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: widthPx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw XCTSkip("could not create CGContext for fixture image")
        }

        // White background, large black text
        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 60, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1.0),
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let textRect = CGRect(x: 20, y: 20, width: widthPx - 40, height: heightPx - 40)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)

        guard let cgImage = context.makeImage() else {
            throw XCTSkip("could not make CGImage from context")
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("searchable-pdf-test-\(UUID().uuidString).tiff")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw XCTSkip("could not create CGImageDestination")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("could not finalize TIFF")
        }
        return url
    }

    private func extractText(from pdfURL: URL) -> String {
        guard let pdf = PDFDocument(url: pdfURL) else { return "" }
        var out = ""
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let s = page.string {
                out += s
            }
        }
        return out
    }

    func testAssembleProducesPDFWithOnePage() throws {
        let tiff = try makeTIFF(text: "Hello")
        defer { try? FileManager.default.removeItem(at: tiff) }

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let result = SearchablePDF.assemble(
            pageTIFFs: [tiff],
            outputURL: outURL,
            searchable: false
        )
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(PDFDocument(url: outURL)?.pageCount, 1)
    }

    func testAssembleMultipage() throws {
        let tiff1 = try makeTIFF(text: "PAGE ONE")
        let tiff2 = try makeTIFF(text: "PAGE TWO")
        defer {
            try? FileManager.default.removeItem(at: tiff1)
            try? FileManager.default.removeItem(at: tiff2)
        }

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let result = SearchablePDF.assemble(
            pageTIFFs: [tiff1, tiff2],
            outputURL: outURL,
            searchable: false
        )

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(PDFDocument(url: outURL)?.pageCount, 2)
    }

    func testSearchableLayerEmbedsRecognizedText() throws {
        // Use a longer, less ambiguous string to give Vision plenty of signal.
        let knownText = "MCP Scanner Helper Searchable PDF Test"
        let tiff = try makeTIFF(text: knownText)
        defer { try? FileManager.default.removeItem(at: tiff) }

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let result = SearchablePDF.assemble(
            pageTIFFs: [tiff],
            outputURL: outURL,
            searchable: true
        )
        XCTAssertNoThrow(try result.get())

        let extracted = extractText(from: outURL)
        XCTAssertFalse(extracted.isEmpty, "searchable PDF must yield non-empty text via PDFKit")

        // Vision OCR isn't perfect; check for substantial substring overlap rather than equality.
        // "MCP Scanner Helper" or "Searchable PDF Test" should each show up if the layer is working.
        let lowered = extracted.lowercased()
        let hasSomeKnownWord = lowered.contains("scanner")
            || lowered.contains("searchable")
            || lowered.contains("helper")
            || lowered.contains("test")
        XCTAssertTrue(
            hasSomeKnownWord,
            "extracted text should contain at least one expected word from the source. Got: '\(extracted)'"
        )
    }

    func testEmptyInputReturnsFailure() {
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).pdf")
        let result = SearchablePDF.assemble(pageTIFFs: [], outputURL: outURL, searchable: false)

        switch result {
        case .success:
            XCTFail("expected failure for empty input")
        case .failure:
            break  // expected
        }
    }
}
