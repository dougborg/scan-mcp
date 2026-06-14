import ArgumentParser
import Foundation
import ImageCaptureCore

// Keeps the controller alive while CFRunLoop runs. ICScannerDevice.delegate is
// weak, so a local-scoped controller would be deallocated before any callbacks
// fire — silent hang. The process is single-threaded under CFRunLoopRun, so
// nonisolated(unsafe) is sound here.
nonisolated(unsafe) private var activeScanController: ScannerController?

@MainActor
struct Scan: @preconcurrency ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Drive a scanner to capture pages into an output directory.",
        discussion: """
            Emits one JSON object per line on stdout while scanning:
              {"type":"stage","stage":"discovering","timestamp":"..."}
              {"type":"stage","stage":"scanning","timestamp":"..."}
              {"type":"page_scanned","index":1,"path":"...","timestamp":"..."}
              ...
            After scanning completes, emits a final result line:
              {"type":"complete","pages":[...],"document":"...","timestamp":"..."}
            On failure, emits:
              {"type":"error","message":"...","timestamp":"..."}
            """
    )

    @Option(name: .customLong("params"), help: "JSON-encoded ScanParams object.")
    var paramsJSON: String

    @Option(name: .customLong("out-dir"), help: "Directory to write per-page TIFFs into.")
    var outDir: String

    @Option(name: .customLong("browse-seconds"), help: "How long to look for the scanner.")
    var browseSeconds: Double = 8.0

    @Flag(name: .shortAndLong, help: "Emit verbose diagnostic logs to stderr.")
    var verbose: Bool = false

    func run() throws {
        Log.mirrorToStderr = verbose
        let params: ScanParams
        do {
            guard let data = paramsJSON.data(using: .utf8) else {
                throw NSError(domain: "mcp-scanner-helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "params not valid UTF-8"])
            }
            params = try JSONDecoder().decode(ScanParams.self, from: data)
        } catch {
            JSONOut.line(ScanEvent.error("invalid params JSON: \(error.localizedDescription)"))
            throw ExitCode.failure
        }

        let outDirURL = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

        JSONOut.line(ScanEvent.stage("discovering"))

        let browser = ScannerBrowser(browseSeconds: browseSeconds)
        var didStart = false

        browser.start {
            if !didStart {
                JSONOut.line(ScanEvent.error("no scanner found within \(browseSeconds)s"))
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }
        browser.waitForDevice(matching: params.device_id) { scanner in
            didStart = true
            startScan(scanner: scanner, params: params, outDir: outDirURL)
        }
        CFRunLoopRun()
    }

    private func startScan(scanner: ICScannerDevice, params: ScanParams, outDir: URL) {
        let controller = ScannerController(scanner: scanner, params: params, outDir: outDir, emitEvents: true)
        activeScanController = controller
        controller.start { result in
            activeScanController = nil
            switch result {
            case .success(let pages):
                emitComplete(pages: pages, params: params, outDir: outDir)
                CFRunLoopStop(CFRunLoopGetCurrent())
            case .failure(let err):
                JSONOut.line(ScanEvent.error(err.localizedDescription))
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }
    }

    private func emitComplete(pages: [URL], params: ScanParams, outDir: URL) {
        let outputFormat = params.output_format ?? .tiff
        var documentPath: String? = nil
        var ocrConfidence: [SearchablePDF.PageConfidence]? = nil

        if outputFormat == .pdf || outputFormat == .pdfSearchable {
            JSONOut.line(ScanEvent.stage("finalizing"))
            let pdfURL = outDir.appendingPathComponent("doc_0001.pdf")
            let result = SearchablePDF.assemble(
                pageTIFFs: pages,
                outputURL: pdfURL,
                searchable: outputFormat == .pdfSearchable
            )
            switch result {
            case .success(let confidences):
                documentPath = pdfURL.path
                ocrConfidence = confidences.isEmpty ? nil : confidences
            case .failure(let err):
                JSONOut.diagnostic("PDF assembly failed: \(err.localizedDescription)")
            }
        }

        JSONOut.line(CompleteEvent(
            timestamp: JSONOut.iso8601.string(from: Date()),
            pages: pages.map { $0.path },
            document: documentPath,
            ocrConfidence: ocrConfidence
        ))
    }
}

private struct CompleteEvent: Encodable {
    let type = "complete"
    let timestamp: String
    let pages: [String]
    let document: String?
    let ocrConfidence: [SearchablePDF.PageConfidence]?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, pages, document
        case ocrConfidence = "ocr_confidence"
    }
}
