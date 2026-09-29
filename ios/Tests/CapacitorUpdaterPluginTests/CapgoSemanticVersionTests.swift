import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

final class CapgoSemanticVersionTests: XCTestCase {
    private func version(_ string: String) throws -> CapgoSemanticVersion {
        return try CapgoSemanticVersion(string)
    }

    func testParsesComponents() throws {
        let full = try version("1.2.3-beta.1+build5")
        XCTAssertEqual(full.major, 1)
        XCTAssertEqual(full.minor, 2)
        XCTAssertEqual(full.patch, 3)
        XCTAssertEqual(full.prerelease, "beta.1")
        XCTAssertEqual(full.build, "build5")
        XCTAssertEqual(full.description, "1.2.3-beta.1+build5")

        // Lenient parsing like the previous Version package: minor/patch optional, leading zeros allowed.
        XCTAssertEqual(try version("7").description, "7")
        XCTAssertEqual(try version("7.1").description, "7.1")
        XCTAssertEqual(try version("01.002.0003").description, "1.2.3")
        XCTAssertEqual(try version("1.0.0-rc-1.x-y").prerelease, "rc-1.x-y")
    }

    func testRejectsInvalidStrings() {
        let invalid = [
            "", " 1.0.0", "1.0.0 ", "v1.0.0", "1.0.0.0", "1..0", "1.0.", "a.b.c", "1.0.0-", "1.0.0+", "1.0.0+build.1",
            "1.0.0-be ta", "1.0.0-β", "99999999999999999999.0.0", "1.99999999999999999999.0", "1.0.99999999999999999999"
        ]
        for string in invalid {
            XCTAssertThrowsError(try version(string), "\(string) must not parse")
        }
    }

    func testOrdering() throws {
        XCTAssertTrue(try version("1.0.0") < version("1.0.1"))
        XCTAssertTrue(try version("1.0.9") < version("1.0.10"))
        XCTAssertTrue(try version("1.9.0") < version("1.10.0"))
        XCTAssertTrue(try version("1.99.99") < version("2.0.0"))
        XCTAssertTrue(try version("1.0.0-alpha") < version("1.0.0"))
        XCTAssertTrue(try version("1.0.0-alpha") < version("1.0.0-alpha.1"))
        XCTAssertTrue(try version("1.0.0-alpha.1") < version("1.0.0-beta"))
        XCTAssertTrue(try version("1.0.0-beta.2") < version("1.0.0-beta.11"))
        XCTAssertTrue(try version("1.0.0-rc.1") < version("1.0.0"))
        XCTAssertFalse(try version("1.0.0") < version("1.0.0-rc.1"))
        XCTAssertTrue(try version("2.1.0") > version("2.0.9"))
        XCTAssertTrue(try version("1.0.0") >= version("1.0.0"))
        XCTAssertTrue(try version("1.0.0") <= version("1.0.0"))
    }

    func testMissingComponentsCompareAsZeroAndBuildIsIgnored() throws {
        XCTAssertEqual(try version("1"), try version("1.0.0"))
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertEqual(try version("1.0.0+a"), try version("1.0.0+b"))
        XCTAssertFalse(try version("1.0.0+a") < version("1.0.0+b"))
        XCTAssertEqual(Set([try version("1.0"), try version("1.0.0+x")]).count, 1)
        XCTAssertNotEqual(try version("1.0.0-a"), try version("1.0.0"))
    }

    func testDefaultVersionDescription() {
        XCTAssertEqual(CapgoSemanticVersion(major: 0, minor: 0, patch: 0).description, "0.0.0")
    }
}
