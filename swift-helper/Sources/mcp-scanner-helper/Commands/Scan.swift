import ArgumentParser
import Foundation
import ImageCaptureCore

// Keeps the controller alive while CFRunLoop runs. ICScannerDevice.delegate is
// weak, so a local-scoped controller would be deallocated before any callbacks
// fire — silent hang.
private var activeScanController: ScannerController?

struct Scan: ParsableCommand {
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
        JSONOut.verboseEnabled = verbose
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

        let browser = ScannerBrowser(
            targetName: params.device_id,
            exactMatch: false,
            browseSeconds: browseSeconds
        )

        var didStart = false

        browser.start(
            onMatch: { _ in /* match by persistent id below */ },
            onTimeout: {
                if !didStart {
                    JSONOut.line(ScanEvent.error("no scanner found within \(browseSeconds)s"))
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
            }
        )

        // Poll for a matching persistentIDString. Browser's name-based match is a fallback;
        // we prefer matching by ID since the TS side ships persistentIDString.
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            let device: ICScannerDevice?
            if let id = params.device_id {
                device = browser.discovered.first { $0.persistentIDString == id || $0.name == id }
            } else {
                // No device specified — take the first discovered scanner.
                device = browser.discovered.first
            }
            guard let scanner = device else { return }
            timer.invalidate()
            browser.stopBrowsing()
            didStart = true
            startScan(scanner: scanner, params: params, outDir: outDirURL)
        }
        _ = pollTimer
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
        let outputFormat = params.output_format ?? "tiff"
        var documentPath: String? = nil

        if outputFormat == "pdf" || outputFormat == "pdf-searchable" {
            JSONOut.line(ScanEvent.stage("finalizing"))
            let pdfURL = outDir.appendingPathComponent("doc_0001.pdf")
            let result = SearchablePDF.assemble(
                pageTIFFs: pages,
                outputURL: pdfURL,
                searchable: outputFormat == "pdf-searchable"
            )
            switch result {
            case .success:
                documentPath = pdfURL.path
            case .failure(let err):
                JSONOut.diagnostic("PDF assembly failed: \(err.localizedDescription)")
            }
        }

        JSONOut.line(CompleteEvent(
            type: "complete",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            pages: pages.map { $0.path },
            document: documentPath
        ))
    }
}

private struct CompleteEvent: Encodable {
    let type: String
    let timestamp: String
    let pages: [String]
    let document: String?
}
