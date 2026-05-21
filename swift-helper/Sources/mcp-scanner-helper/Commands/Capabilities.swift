import ArgumentParser
import Foundation

struct Capabilities: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Report the helper's capabilities (macOS version, AI feature availability, supported output formats)."
    )

    func run() throws {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let macosVersion = "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"

        var aiAvailable = false
        var aiReason: String? = nil
        if #available(macOS 26.0, *) {
            // FoundationModels availability check is intentionally lazy here — we
            // emit the boolean and the TS side surfaces it.
            // Importing FoundationModels conditionally would require @_unsafeInheritExecutor
            // or a fallback target. For v0 we report based on macOS version only;
            // a future revision can actually call SystemLanguageModel.default.availability.
            aiAvailable = true
        } else {
            aiReason = "FoundationModels requires macOS 26+ (current: \(macosVersion))"
        }

        let response = CapabilitiesJSON(
            helper_version: "0.1.0",
            macos_version: macosVersion,
            ai_available: aiAvailable,
            ai_reason: aiReason,
            output_formats: ["tiff", "pdf", "pdf-searchable"]
        )
        JSONOut.line(response)
    }
}

private struct CapabilitiesJSON: Encodable {
    let helper_version: String
    let macos_version: String
    let ai_available: Bool
    let ai_reason: String?
    let output_formats: [String]
}
