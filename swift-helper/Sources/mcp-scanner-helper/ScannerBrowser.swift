// Adapted from scanline (https://github.com/klep/scanline), MIT licensed.
// See LICENSE-scanline and NOTICE.md for attribution.

import Foundation
import ImageCaptureCore

final class ScannerBrowser: NSObject, ICDeviceBrowserDelegate {
    private let deviceBrowser = ICDeviceBrowser()
    private(set) var discovered: [ICScannerDevice] = []
    private var targetName: String?
    private var exactMatch: Bool
    private var onMatch: ((ICScannerDevice) -> Void)?
    private var onTimeout: (() -> Void)?
    private var timer: Timer?
    private var browseSeconds: TimeInterval

    init(targetName: String? = nil, exactMatch: Bool = false, browseSeconds: TimeInterval = 5.0) {
        self.targetName = targetName
        self.exactMatch = exactMatch
        self.browseSeconds = browseSeconds
        super.init()
        deviceBrowser.delegate = self
        // Discover scanners over USB (local), Bonjour/AirScan (network), and
        // macOS-shared devices. Same mask Image Capture uses.
        let mask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue |
            ICDeviceLocationTypeMask.local.rawValue |
            ICDeviceLocationTypeMask.bonjour.rawValue |
            ICDeviceLocationTypeMask.shared.rawValue
        )!
        deviceBrowser.browsedDeviceTypeMask = mask
    }

    /// Begin browsing. `onMatch` fires when a device matching targetName is found
    /// (if targetName was set); otherwise wait until `onTimeout` after browseSeconds.
    func start(onMatch: @escaping (ICScannerDevice) -> Void, onTimeout: @escaping () -> Void) {
        self.onMatch = onMatch
        self.onTimeout = onTimeout
        JSONOut.verboseLog("browser: starting (mask=scanner|local|bonjour|shared, window=\(browseSeconds)s)")
        deviceBrowser.start()
        timer = Timer.scheduledTimer(withTimeInterval: browseSeconds, repeats: false) { [weak self] _ in
            JSONOut.verboseLog("browser: timeout window reached, stopping")
            self?.stopBrowsing()
            self?.onTimeout?()
        }
    }

    func stopBrowsing() {
        timer?.invalidate()
        timer = nil
        deviceBrowser.stop()
    }

    private func matches(_ device: ICScannerDevice) -> Bool {
        guard let target = targetName else { return false }
        guard let name = device.name else { return false }
        if exactMatch {
            return target == name
        }
        return name.lowercased().hasPrefix(target.lowercased())
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        JSONOut.verboseLog("browser: added \(scanner.name ?? "[unnamed]") (id=\(scanner.persistentIDString ?? "?"))")
        discovered.append(scanner)
        if matches(scanner) {
            JSONOut.verboseLog("browser: match found, stopping early")
            stopBrowsing()
            onMatch?(scanner)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        discovered.removeAll { $0 === scanner }
    }
}
