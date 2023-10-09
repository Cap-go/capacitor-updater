import XCTest
@testable import Plugin

class CapacitorUpdaterTests: XCTestCase {

    func testEcho() {
        // This is an example of a functional test case for a plugin.
        // Use XCTAssert and related functions to verify your tests produce the correct results.

        let implementation = CapacitorUpdater()
        let value = "Hello, World!"
        let result = implementation.updateApp(value)

        XCTAssertEqual(true, result)
    }
}
