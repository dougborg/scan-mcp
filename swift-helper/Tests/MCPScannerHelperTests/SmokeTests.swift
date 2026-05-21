import XCTest

final class SmokeTests: XCTestCase {
    func testPackageBuilds() {
        // Sanity test so the test target has at least one symbol.
        // Real coverage of ICA paths requires a hardware scanner and lives in the
        // upstream Node-side test suite.
        XCTAssertTrue(true)
    }
}
