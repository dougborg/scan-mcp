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

    /// One recognized line of text, extracted from Vision's (non-`Sendable`)
    /// `VNRecognizedTextObservation` so results can be collected from the
    /// concurrent OCR pass. `boundingBox` is Vision's normalized [0,1] rect,
    /// bottom-left origin.
    private struct OCRLine {
        let text: String
        let boundingBox: CGRect
    }

    /// Assemble per-page TIFFs into a multipage PDF. When `searchable` is true,
    /// OCR is run on every page concurrently (Vision is thread-safe) before the
    /// pages are drawn sequentially into the single-threaded `CGPDFContext`.
    ///
    /// The OCR pass uses `DispatchQueue.concurrentPerform` rather than Swift
    /// concurrency: `VNImageRequestHandler.perform` is a blocking call, and
    /// running many of them as `Task`s would saturate (and deadlock) the
    /// cooperative thread pool. GCD scales its worker threads to fit instead.
    static func assemble(pageTIFFs: [URL], outputURL: URL, searchable: Bool) -> Result<Void, Error> {
        guard !pageTIFFs.isEmpty else {
            return .failure(error("no pages to assemble"))
        }

        // Create the PDF context up front: it's cheap and rarely fails, but
        // failing here after a full parallel OCR pass would waste that work.
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

        // Pass 1 — OCR (parallel). Only when a searchable layer is requested;
        // image-only PDFs skip Vision entirely. Results are keyed by page index
        // so the sequential draw pass can stay in order.
        var ocrByIndex: [Int: [OCRLine]] = [:]
        if searchable {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: pageTIFFs.count) { i in
                guard let lines = ocrPage(at: pageTIFFs[i], index: i) else { return }
                lock.lock()
                defer { lock.unlock() }
                ocrByIndex[i] = lines
            }
        }

        // Pass 2 — draw pages in order into the (single-threaded) PDF context,
        // overlaying the cached OCR lines as an invisible text layer.
        for (i, tiffURL) in pageTIFFs.enumerated() {
            guard let (cgImage, pageSize) = loadImageAndSize(at: tiffURL) else {
                JSONOut.diagnostic("warning: could not load page \(tiffURL.lastPathComponent)")
                continue
            }
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            pdfContext.beginPage(mediaBox: &mediaBox)
            pdfContext.draw(cgImage, in: mediaBox)
            if searchable, let lines = ocrByIndex[i] {
                drawCachedTextLayer(lines, pageRect: mediaBox, into: pdfContext)
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

    /// Run Vision OCR on a single page and return its recognized lines. Loads
    /// (and discards) the image here so the parallel OCR pass never holds every
    /// decoded page in memory at once. Returns nil only when the image can't be
    /// loaded; an OCR failure yields an empty (but present) result.
    private static func ocrPage(at url: URL, index: Int) -> [OCRLine]? {
        guard let (cgImage, _) = loadImageAndSize(at: url) else {
            JSONOut.diagnostic("warning: could not load page \(url.lastPathComponent) for OCR")
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            JSONOut.diagnostic("OCR failed on page \(index + 1): \(error.localizedDescription)")
            return []
        }

        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            // Vision's boundingBox is normalized [0,1] in bottom-left origin (same as PDF page).
            return OCRLine(text: candidate.string, boundingBox: obs.boundingBox)
        }
    }

    /// Draw the cached OCR lines for one page as an invisible, extractable text layer.
    private static func drawCachedTextLayer(_ lines: [OCRLine], pageRect: CGRect, into pdfContext: CGContext) {
        for line in lines {
            let bbox = line.boundingBox
            let pdfRect = CGRect(
                x: bbox.origin.x * pageRect.width,
                y: bbox.origin.y * pageRect.height,
                width: bbox.width * pageRect.width,
                height: bbox.height * pageRect.height
            )
            drawInvisibleLine(text: line.text, in: pdfRect, into: pdfContext)
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
