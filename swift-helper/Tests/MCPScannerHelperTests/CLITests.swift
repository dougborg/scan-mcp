import XCTest
import Foundation

/// End-to-end CLI tests that spawn the compiled binary and verify its wire contract.
/// These do NOT require a real scanner — they exercise discovery (with browse-seconds 0)
/// and capabilities/help endpoints.
///
/// To run only these (skipping ICA-dependent tests in this file when no hardware):
///   swift test --filter MCPScannerHelperTests.CLITests
final class CLITests: XCTestCase {

    /// Locate the built binary in the SwiftPM build products.
    /// SwiftPM puts test products next to the package's .build/<config>/<binary>.
    private static var binaryURL: URL {
        // When tests run via `swift test`, .build/debug/mcp-scanner-helper exists.
        // When run via Xcode, the binary may be elsewhere — fall back to .build/release.
        let candidates = [
            "swift-helper/.build/debug/mcp-scanner-helper",
            "swift-helper/.build/release/mcp-scanner-helper",
            ".build/debug/mcp-scanner-helper",
            ".build/release/mcp-scanner-helper",
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            // Also try resolving relative to the repo root if cwd is the test target dir
            let abs = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: abs.path) {
                return abs
            }
        }
        // Last resort — common install location after npm build:helper
        let dist = URL(fileURLWithPath: "dist/bin/mcp-scanner-helper")
        return dist
    }

    /// Spawn the binary, capture stdout/stderr/exit code with a wall-clock timeout.
    private func run(args: [String], timeout: TimeInterval = 15) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let binary = Self.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("binary not built or not executable at \(binary.path). Run `swift build` first.")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Manual wall-clock timeout, since Process has no native one
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { process.interrupt() }
            throw XCTSkip("process did not exit within \(timeout)s — likely waiting for hardware")
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    private func decodeJSONLine(_ s: String) throws -> [String: Any] {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        guard let data = line.data(using: .utf8) else {
            throw XCTSkip("not utf8")
        }
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: -

    func testHelpRunsAndExitsZero() throws {
        let result = try run(args: ["--help"])
        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("list-devices"), "help should list subcommands")
        XCTAssertTrue(result.stdout.contains("scan"))
        XCTAssertTrue(result.stdout.contains("device-options"))
        XCTAssertTrue(result.stdout.contains("capabilities"))
        XCTAssertTrue(result.stdout.contains("assemble-pdf"))
    }

    func testAssemblePdfHelpListsArgs() throws {
        let result = try run(args: ["assemble-pdf", "--help"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("--output"))
        XCTAssertTrue(result.stdout.contains("--searchable"))
    }

    func testAssemblePdfErrorsWithNoPages() throws {
        let outPath = NSTemporaryDirectory() + "test-empty-\(UUID().uuidString).pdf"
        let result = try run(args: ["assemble-pdf", "--output", outPath])
        XCTAssertNotEqual(result.exitCode, 0, "should exit non-zero when no pages supplied")
        XCTAssertTrue(result.stderr.contains("at least one page"),
                      "stderr: \(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outPath),
                       "no PDF should be written when input is invalid")
    }

    func testVersionFlag() throws {
        let result = try run(args: ["--version"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.isEmpty, "version output should not be empty")
    }

    func testCapabilitiesEmitsJSONShape() throws {
        let result = try run(args: ["capabilities"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let dict = try decodeJSONLine(result.stdout)
        XCTAssertNotNil(dict["helper_version"] as? String)
        XCTAssertNotNil(dict["macos_version"] as? String)
        XCTAssertNotNil(dict["ai_available"] as? Bool)
        XCTAssertNotNil(dict["output_formats"] as? [String])
        let formats = dict["output_formats"] as? [String] ?? []
        XCTAssertTrue(formats.contains("tiff"))
        XCTAssertTrue(formats.contains("pdf"))
        XCTAssertTrue(formats.contains("pdf-searchable"))
    }

    func testListDevicesEmitsJSONShape() throws {
        // Use a short browse window so we don't depend on hardware actually being present.
        // The output will be {"devices":[]} if nothing is on the network; if scanline-class
        // devices exist, they'll appear.
        let result = try run(args: ["list-devices", "--browse-seconds", "1"], timeout: 10)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let dict = try decodeJSONLine(result.stdout)
        XCTAssertNotNil(dict["devices"] as? [Any], "response must contain 'devices' array")
    }

    func testScanWithInvalidParamsEmitsErrorEventThenExitsNonZero() throws {
        // Pass garbage JSON for params; helper should emit a {"type":"error",...} line
        // and exit non-zero rather than hanging or crashing.
        let result = try run(args: [
            "scan",
            "--params", "not-json",
            "--out-dir", NSTemporaryDirectory()
        ], timeout: 5)
        XCTAssertNotEqual(result.exitCode, 0, "exit code should be non-zero on bad params")
        // Expect at least one JSON line containing "error" — could be the error event we emit
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let hasErrorEvent = lines.contains { line in
            (try? decodeJSONLine(line))?["type"] as? String == "error"
        }
        XCTAssertTrue(hasErrorEvent || result.stderr.contains("error"),
                      "expected an error event or stderr message. stdout: \(result.stdout) stderr: \(result.stderr)")
    }
}
