import Foundation

/// Structured JSON output for one-line events and final tool results.
/// All output goes to stdout. Diagnostic / progress messages go to stderr.
enum JSONOut {
    /// Toggle by --verbose; gates the verboseLog() output.
    nonisolated(unsafe) static var verboseEnabled = false

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []  // single-line, no pretty-print
        return e
    }()

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

    /// Verbose-only log to stderr, prefixed with [verbose]. Shown only when --verbose is set.
    static func verboseLog(_ msg: @autoclosure () -> String) {
        guard verboseEnabled else { return }
        FileHandle.standardError.write(Data(("[verbose] " + msg() + "\n").utf8))
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

    private init(
        type: String,
        stage: String? = nil,
        index: Int? = nil,
        path: String? = nil,
        message: String? = nil,
        data: [String: AnyEncodable]? = nil
    ) {
        self.type = type
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.stage = stage
        self.index = index
        self.path = path
        self.message = message
        self.data = data
    }

    static func stage(_ name: String) -> ScanEvent {
        ScanEvent(type: "stage", stage: name)
    }
    static func pageScanned(index: Int, path: String) -> ScanEvent {
        ScanEvent(type: "page_scanned", index: index, path: path)
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
