import Foundation

/// JSON shape matching the TS-side StartScanInput.
/// Decoded from `--params <json>` on the `scan` subcommand.
struct ScanParams: Codable {
    var device_id: String?
    var resolution_dpi: Int?
    var color_mode: ColorMode?
    var source: Source?
    var duplex: Bool?
    var page_size: PageSize?
    var custom_size_mm: SizeMM?
    var output_format: OutputFormat?
    var ocr: Bool?
    var autoname: Bool?
    var summarize: Bool?

    struct SizeMM: Codable {
        var width: Double
        var height: Double
    }

    /// Matches the TS-side enum exactly so the JSON wire shape stays untyped strings.
    /// Defaults to .color when omitted.
    enum ColorMode: String, Codable {
        case color = "Color"
        case gray = "Gray"
        case lineart = "Lineart"
        case halftone = "Halftone"
    }

    enum Source: String, Codable {
        case flatbed = "Flatbed"
        case adf = "ADF"
        case adfDuplex = "ADF Duplex"

        var wantsADF: Bool { self == .adf || self == .adfDuplex }
        var wantsDuplex: Bool { self == .adfDuplex }
    }

    enum PageSize: String, Codable {
        case letter = "Letter"
        case a4 = "A4"
        case legal = "Legal"
        case custom = "Custom"
    }

    enum OutputFormat: String, Codable {
        case tiff = "tiff"
        case pdf = "pdf"
        case pdfSearchable = "pdf-searchable"
    }
}
