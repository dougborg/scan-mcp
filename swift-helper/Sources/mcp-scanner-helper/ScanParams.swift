import Foundation

/// JSON shape matching the TS-side StartScanInput.
/// Decoded from `--params <json>` on the `scan` subcommand.
struct ScanParams: Codable {
    var device_id: String?
    var resolution_dpi: Int?
    var color_mode: String?       // "Color" | "Gray" | "Lineart" | "Halftone" | ...
    var source: String?           // "Flatbed" | "ADF" | "ADF Duplex"
    var duplex: Bool?
    var page_size: String?        // "Letter" | "A4" | "Legal" | "Custom"
    var custom_size_mm: SizeMM?
    var output_format: String?    // "tiff" | "pdf" | "pdf-searchable"
    var ocr: Bool?
    var autoname: Bool?
    var summarize: Bool?

    struct SizeMM: Codable {
        var width: Double
        var height: Double
    }
}
