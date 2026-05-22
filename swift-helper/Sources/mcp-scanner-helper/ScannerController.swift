// Adapted from scanline (https://github.com/klep/scanline), MIT licensed.
// See LICENSE-scanline and NOTICE.md for attribution.

import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

@MainActor
final class ScannerController: NSObject, @preconcurrency ICScannerDeviceDelegate {
    let scanner: ICScannerDevice
    let params: ScanParams
    private(set) var scannedURLs: [URL] = []
    private var pageCounter = 0
    private let outDir: URL
    private let emitEvents: Bool
    private var onComplete: ((Result<[URL], Error>) -> Void)?
    private var sessionTimer: Timer?
    private var sessionOpened = false

    /// True if the params request the document-feeder functional unit, false for flatbed.
    private var wantsADF: Bool {
        guard let src = params.source else { return false }
        return src.uppercased().contains("ADF")
    }

    init(scanner: ICScannerDevice, params: ScanParams, outDir: URL, emitEvents: Bool) {
        self.scanner = scanner
        self.params = params
        self.outDir = outDir
        self.emitEvents = emitEvents
        super.init()
        self.scanner.delegate = self
    }

    /// Begin scanning. `onComplete` is called once at the end (success or failure).
    func start(onComplete: @escaping (Result<[URL], Error>) -> Void) {
        self.onComplete = onComplete
        if emitEvents {
            JSONOut.line(ScanEvent.stage("opening_session"))
        }
        Log.controller.debug("requesting session on \(scanner.name ?? "[unnamed]")")
        // 30s watchdog so a denied Local Network permission (or any other stall)
        // surfaces as an error event rather than a silent hang.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, !self.sessionOpened else { return }
                self.fail("session open timed out after 30s — likely a macOS permissions issue. Try running once interactively to trigger the Privacy & Security prompt, or check System Settings → Privacy & Security → Local Network.")
            }
        }
        scanner.requestOpenSession()
    }

    // MARK: - ICScannerDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Log.controller.debug("didOpenSessionWithError error=\(error?.localizedDescription ?? "nil")")
        sessionOpened = true
        sessionTimer?.invalidate()
        sessionTimer = nil
        if let error = error {
            fail("opening session failed: \(error.localizedDescription)")
            return
        }
        // Wait for deviceDidBecomeReady before issuing further commands.
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Log.controller.debug("didCloseSessionWithError error=\(error?.localizedDescription ?? "nil")")
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        Log.controller.error("didEncounterError error=\(error?.localizedDescription ?? "nil")")
        fail("device error: \(error?.localizedDescription ?? "unknown")")
    }

    func didRemove(_ device: ICDevice) {
        Log.controller.debug("didRemove")
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        Log.controller.debug("deviceDidBecomeReady, wantsADF=\(wantsADF)")
        if emitEvents {
            JSONOut.line(ScanEvent.stage("selecting_functional_unit"))
        }
        let unitType: ICScannerFunctionalUnitType = wantsADF ? .documentFeeder : .flatbed
        scanner.requestSelect(unitType)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        Log.controller.debug("didSelect functionalUnit type=\(functionalUnit.type.rawValue) error=\(error?.localizedDescription ?? "nil")")
        if let error = error {
            fail("selecting functional unit failed: \(error.localizedDescription)")
            return
        }
        // ICA quirk (per scanline): `functionalUnit` is non-optional in the signature
        // but sometimes arrives as nil in release builds. unsafeBitCast to Int and
        // check the address. If nil OR not the unit we want, just return and wait
        // for the next selection callback — scanner will retry.
        let address = unsafeBitCast(functionalUnit, to: Int.self)
        let wantedType: ICScannerFunctionalUnitType = wantsADF ? .documentFeeder : .flatbed
        guard address != 0, functionalUnit.type == wantedType else {
            Log.controller.debug("waiting for correct functional unit (got address=\(address), type=\(functionalUnit.type.rawValue), wanted=\(wantedType.rawValue))")
            return
        }
        configure(functionalUnit: functionalUnit)
        if emitEvents {
            JSONOut.line(ScanEvent.stage("scanning"))
        }
        scanner.requestScan()
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        Log.controller.debug("didScanTo \(url.path)")
        pageCounter += 1
        let dest = outDir.appendingPathComponent(String(format: "page_%04d.tiff", pageCounter))
        do {
            // Move the per-page TIFF from ICA's downloadsDirectory into our outDir
            // with the page_NNNN.tiff naming the TS side expects.
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: url, to: dest)
            scannedURLs.append(dest)
            if emitEvents {
                JSONOut.line(ScanEvent.pageScanned(index: pageCounter, path: dest.path))
            }
        } catch {
            JSONOut.diagnostic("warning: failed to move page \(pageCounter): \(error.localizedDescription)")
            scannedURLs.append(url)
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        Log.controller.debug("didCompleteScanWithError error=\(error?.localizedDescription ?? "nil") pages=\(scannedURLs.count)")
        if let error = error {
            // ADF "no more pages" is a normal end-of-batch — surface as success.
            let nsError = error as NSError
            // ICA error codes: ICError.scannerOutOfPaper.rawValue is the typical "feed done" code.
            // Treat -9923 / -9924 / "no more pages" message as success.
            let msg = nsError.localizedDescription.lowercased()
            let endOfBatch = msg.contains("no more pages")
                || msg.contains("nothing to scan")
                || nsError.code == -9923
            if endOfBatch && !scannedURLs.isEmpty {
                succeed()
                return
            }
            fail("scan failed: \(nsError.localizedDescription) [code=\(nsError.code)]")
            return
        }
        succeed()
    }

    // MARK: - Configuration

    private func configure(functionalUnit unit: ICScannerFunctionalUnit) {
        // Resolution: pick the requested DPI, falling back to the closest supported value at or above.
        let desiredDPI = params.resolution_dpi ?? 300
        if let dpiIdx = unit.supportedResolutions.integerGreaterThanOrEqualTo(desiredDPI) {
            unit.resolution = dpiIdx
        } else if let maxDPI = unit.supportedResolutions.last {
            unit.resolution = maxDPI
        }

        // Color mode
        switch (params.color_mode ?? "").lowercased() {
        case "lineart", "bw", "binary", "mono":
            unit.pixelDataType = .BW
            unit.bitDepth = .depth1Bit
        case "gray", "grayscale":
            unit.pixelDataType = .gray
            unit.bitDepth = .depth8Bits
        default:
            unit.pixelDataType = .RGB
            unit.bitDepth = .depth8Bits
        }

        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = mapDocumentType(params.page_size)
            feeder.duplexScanningEnabled = (params.duplex ?? false) || (params.source?.lowercased().contains("duplex") ?? false)
        }

        if let flatbed = unit as? ICScannerFunctionalUnitFlatbed {
            flatbed.measurementUnit = .inches
            let physical = flatbed.physicalSize
            flatbed.scanArea = NSMakeRect(0, 0, physical.width, physical.height)
        }

        // Output settings — ICA writes per-page files into downloadsDirectory using
        // documentName as the basename. We hand it our outDir and then rename in didScanTo.
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = outDir
        scanner.documentName = "ica_scratch"
        // Always request TIFF from the scanner; PDF/searchable-PDF synthesis happens post-scan.
        scanner.documentUTI = UTType.tiff.identifier
    }

    private func mapDocumentType(_ pageSize: String?) -> ICScannerDocumentType {
        switch pageSize?.lowercased() {
        case "legal": return .typeUSLegal
        case "a4": return .typeA4
        case "letter": return .typeUSLetter
        default: return .typeUSLetter
        }
    }

    // MARK: - Completion

    private func succeed() {
        let cb = onComplete
        onComplete = nil
        cb?(.success(scannedURLs))
    }

    private func fail(_ msg: String) {
        let cb = onComplete
        onComplete = nil
        cb?(.failure(NSError(domain: "mcp-scanner-helper", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])))
    }
}
