import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Vision

/// Generates a multipage PDF from per-page TIFF scans. If `searchable` is true,
/// runs Vision OCR per page and embeds an invisible text layer so the resulting PDF
/// is full-text searchable (like Image Capture's OCR checkbox or Adobe Acrobat's
/// "Recognize Text" output).
enum SearchablePDF {

    static func assemble(pageTIFFs: [URL], outputURL: URL, searchable: Bool) -> Result<Void, Error> {
        guard !pageTIFFs.isEmpty else {
            return .failure(error("no pages to assemble"))
        }

        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let consumer = CGDataConsumer(data: mutableData) else {
            return .failure(error("could not create PDF data consumer"))
        }

        // `mediaBox` here is just the default; beginPage(mediaBox:) overrides it
        // per page. Any non-zero rect works.
        var initialMediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &initialMediaBox, nil) else {
            return .failure(error("could not create CGPDFContext"))
        }

        for tiffURL in pageTIFFs {
            guard let (cgImage, pageSize) = loadImageAndSize(at: tiffURL) else {
                JSONOut.diagnostic("warning: could not load page \(tiffURL.lastPathComponent)")
                continue
            }
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            pdfContext.beginPage(mediaBox: &mediaBox)
            pdfContext.draw(cgImage, in: mediaBox)
            if searchable {
                drawInvisibleTextLayer(
                    cgImage: cgImage,
                    pageRect: mediaBox,
                    into: pdfContext
                )
            }
            pdfContext.endPage()
        }

        pdfContext.closePDF()

        do {
            let data = mutableData as Data
            try data.write(to: outputURL)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SearchablePDF", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Image loading

    private static func loadImageAndSize(at url: URL) -> (CGImage, CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = pageSizeInPoints(source: source, image: cgImage) ?? CGSize(width: cgImage.width, height: cgImage.height)
        return (cgImage, size)
    }

    private static func pageSizeInPoints(source: CGImageSource, image: CGImage) -> CGSize? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let dpiX = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let dpiY = (props[kCGImagePropertyDPIHeight] as? CGFloat) ?? 72
        let widthPts = CGFloat(image.width) / dpiX * 72.0
        let heightPts = CGFloat(image.height) / dpiY * 72.0
        return CGSize(width: widthPts, height: heightPts)
    }

    // MARK: - OCR + invisible text layer

    private static func drawInvisibleTextLayer(cgImage: CGImage, pageRect: CGRect, into pdfContext: CGContext) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            JSONOut.diagnostic("OCR failed: \(error.localizedDescription)")
            return
        }
        guard let observations = request.results else { return }

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            // Vision's boundingBox is normalized [0,1] in bottom-left origin (same as PDF page).
            let bbox = obs.boundingBox
            let pdfRect = CGRect(
                x: bbox.origin.x * pageRect.width,
                y: bbox.origin.y * pageRect.height,
                width: bbox.width * pageRect.width,
                height: bbox.height * pageRect.height
            )
            drawInvisibleLine(text: text, in: pdfRect, into: pdfContext)
        }
    }

    /// Draw one line of invisible-but-extractable text. `setTextDrawingMode(.invisible)`
    /// must be re-set inside saveGState per line — Core Text's runs re-stamp the text
    /// mode from the attributed string's attributes, so a single set at the top of
    /// the caller is silently overridden.
    private static func drawInvisibleLine(text: String, in rect: CGRect, into pdfContext: CGContext) {
        let fontSize = max(4.0, min(72.0, rect.height * 0.85))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrString = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)

        pdfContext.saveGState()
        pdfContext.setTextDrawingMode(.invisible)
        pdfContext.textMatrix = .identity
        pdfContext.textPosition = CGPoint(x: rect.minX, y: rect.minY)
        CTLineDraw(line, pdfContext)
        pdfContext.restoreGState()
    }
}
