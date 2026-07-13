import Foundation

/// Protocol output for the helper. Two channels:
///   * `line(...)` — single-line JSON on stdout; the caller parses one object per line
///   * `diagnostic(...)` — error/warning text on stderr; always visible regardless of --verbose
///
/// Trace logging is in `Log` (os.Logger-backed). Keep them separate: this file
/// is for the protocol clients depend on, not for debug output.
enum JSONOut {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []  // single-line, no pretty-print
        // camelCase Swift properties -> snake_case JSON keys (e.g. meanLuminance
        // -> mean_luminance) to match the TS-side event parser. Existing keys are
        // all single words, so this is a no-op for them.
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// Shared formatter — instantiation cost is non-trivial. ISO8601DateFormatter
    /// is documented thread-safe for reads, so `nonisolated(unsafe)` is sound here.
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    /// Print a JSON object as a single line on stdout.
    static func line<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        if let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        // Force flush — clients reading our stdout line-by-line need this.
        fflush(stdout)
    }

    /// Print a diagnostic message to stderr. Always shown.
    static func diagnostic(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}

/// Events emitted during a scan job. Matches the BackendEvent shape on the TS side.
/// Tagged with type so the Node parser can switch on it.
struct ScanEvent: Encodable {
    let type: String
    let timestamp: String

    // Optional per-type payload fields
    let stage: String?
    let index: Int?
    let path: String?
    let message: String?
    let data: [String: AnyEncodable]?

    // Optional per-page metrics (page_scanned only). Nil fields are omitted.
    let width: Int?
    let height: Int?
    let dpi: Int?
    let meanLuminance: Double?
    let side: String?

    private init(
        type: String,
        stage: String? = nil,
        index: Int? = nil,
        path: String? = nil,
        message: String? = nil,
        data: [String: AnyEncodable]? = nil,
        width: Int? = nil,
        height: Int? = nil,
        dpi: Int? = nil,
        meanLuminance: Double? = nil,
        side: String? = nil
    ) {
        self.type = type
        self.timestamp = JSONOut.iso8601.string(from: Date())
        self.stage = stage
        self.index = index
        self.path = path
        self.message = message
        self.data = data
        self.width = width
        self.height = height
        self.dpi = dpi
        self.meanLuminance = meanLuminance
        self.side = side
    }

    static func stage(_ name: String) -> ScanEvent {
        ScanEvent(type: "stage", stage: name)
    }
    static func pageScanned(
        index: Int,
        path: String,
        width: Int? = nil,
        height: Int? = nil,
        dpi: Int? = nil,
        meanLuminance: Double? = nil,
        side: String? = nil
    ) -> ScanEvent {
        ScanEvent(
            type: "page_scanned",
            index: index,
            path: path,
            width: width,
            height: height,
            dpi: dpi,
            meanLuminance: meanLuminance,
            side: side
        )
    }
    static func warning(_ message: String) -> ScanEvent {
        ScanEvent(type: "warning", message: message)
    }
    static func error(_ message: String) -> ScanEvent {
        ScanEvent(type: "error", message: message)
    }
}

/// Type-erased Encodable container so heterogeneous dicts can be JSON-encoded.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) {
        self._encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
