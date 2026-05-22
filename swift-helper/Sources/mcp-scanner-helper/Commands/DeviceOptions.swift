import ArgumentParser
import Foundation
import ImageCaptureCore

// See Scan.swift — same pattern, ICA delegates are weak.
nonisolated(unsafe) private var activeProber: AnyObject?

@MainActor
struct DeviceOptions: @preconcurrency ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-options",
        abstract: "Open a session with a scanner and report its supported sources, resolutions, and color modes."
    )

    @Option(name: .customLong("device-id"), help: "persistentIDString of the target scanner.")
    var deviceId: String

    @Option(name: .customLong("browse-seconds"), help: "Browse window before giving up.")
    var browseSeconds: Double = 5.0

    @Flag(name: .shortAndLong, help: "Emit verbose diagnostic logs to stderr.")
    var verbose: Bool = false

    func run() throws {
        Log.mirrorToStderr = verbose
        let browser = ScannerBrowser(browseSeconds: browseSeconds)
        var didMatch = false

        browser.start(
            onMatch: { _ in /* we filter manually below */ },
            onTimeout: {
                if !didMatch {
                    JSONOut.line(EmptyOptions())
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
            }
        )

        // Poll discovered devices via a small repeating timer so we can match on persistentIDString.
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            let found: Bool = MainActor.assumeIsolated {
                guard let device = browser.discovered.first(where: { $0.persistentIDString == self.deviceId }) else {
                    return false
                }
                didMatch = true
                browser.stopBrowsing()
                Self.probe(device: device)
                return true
            }
            if found { timer.invalidate() }
        }
        _ = pollTimer
        CFRunLoopRun()
    }

    private static func probe(device: ICScannerDevice) {
        let prober = OptionsProber(scanner: device)
        activeProber = prober
        prober.start { result in
            activeProber = nil
            switch result {
            case .success(let options):
                JSONOut.line(options)
            case .failure(let err):
                JSONOut.diagnostic("device-options failed: \(err.localizedDescription)")
                JSONOut.line(EmptyOptions())
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}

private struct EmptyOptions: Encodable {}

struct OptionsJSON: Encodable {
    let sources: [String]
    let color_modes: [String]
    let resolutions: [Int]
    let adf: Bool
    let duplex: Bool
}

@MainActor
private final class OptionsProber: NSObject, @preconcurrency ICScannerDeviceDelegate {
    let scanner: ICScannerDevice
    private var onComplete: ((Result<OptionsJSON, Error>) -> Void)?

    init(scanner: ICScannerDevice) {
        self.scanner = scanner
        super.init()
        scanner.delegate = self
    }

    func start(_ onComplete: @escaping (Result<OptionsJSON, Error>) -> Void) {
        self.onComplete = onComplete
        Log.prober.debug("requesting session on \(scanner.name ?? "[unnamed]")")
        scanner.requestOpenSession()
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Log.prober.debug("didOpenSessionWithError error=\(error?.localizedDescription ?? "nil")")
        if let error = error {
            fail(error); return
        }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        Log.prober.debug("deviceDidBecomeReady, availableFunctionalUnitTypes=\(scanner.availableFunctionalUnitTypes)")
        // Examine functional units to enumerate sources, resolutions, color modes.
        var sources: [String] = []
        let units = scanner.availableFunctionalUnitTypes
        for unitNum in units {
            switch ICScannerFunctionalUnitType(rawValue: UInt(truncating: unitNum)) {
            case .documentFeeder?:
                sources.append("ADF")
            case .flatbed?:
                sources.append("Flatbed")
            default:
                break
            }
        }

        // Default to selecting the most capable unit to read resolution/color details.
        let preferred: ICScannerFunctionalUnitType = sources.contains("ADF") ? .documentFeeder : .flatbed
        scanner.requestSelect(preferred)

        // Note: requestSelect is async; the rest of enumeration happens in didSelect below.
        // Stash the source list so didSelect can finalize.
        self.partialSources = sources
    }

    private var partialSources: [String] = []

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        if let error = error {
            fail(error); return
        }
        let address = unsafeBitCast(functionalUnit, to: Int.self)
        guard address != 0 else {
            fail(NSError(domain: "mcp-scanner-helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "nil functional unit"]))
            return
        }

        var resolutions: [Int] = []
        functionalUnit.supportedResolutions.forEach { resolutions.append($0) }

        var colorModes: [String] = []
        // ICA reports supported pixel data types via supportedBitDepths / supportedPixelDataTypes
        // The API is a bit awkward — we describe a reasonable canonical set.
        let supportedColor: [ICScannerPixelDataType: String] = [
            .RGB: "Color",
            .gray: "Gray",
            .BW: "Lineart",
        ]
        for (key, label) in supportedColor {
            if functionalUnit.supportedBitDepths.count > 0 {
                colorModes.append(label)
            }
            _ = key
        }
        // Most modern scanners support all three. If we can't determine, emit a safe default.
        if colorModes.isEmpty {
            colorModes = ["Color", "Gray", "Lineart"]
        }

        var adf = partialSources.contains("ADF")
        var duplex = false
        if let feeder = functionalUnit as? ICScannerFunctionalUnitDocumentFeeder {
            duplex = feeder.supportsDuplexScanning
            adf = true
            if duplex && !partialSources.contains("ADF Duplex") {
                partialSources.append("ADF Duplex")
            }
        }

        let opts = OptionsJSON(
            sources: partialSources,
            color_modes: colorModes,
            resolutions: resolutions.sorted(),
            adf: adf,
            duplex: duplex
        )

        let cb = onComplete
        onComplete = nil
        cb?(.success(opts))
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let error = error {
            fail(error)
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) {}
    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {}
    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {}

    private func fail(_ error: Error) {
        let cb = onComplete
        onComplete = nil
        cb?(.failure(error))
    }
}
