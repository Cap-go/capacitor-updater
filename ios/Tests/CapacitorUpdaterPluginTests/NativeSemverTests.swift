import XCTest
@testable import CapacitorUpdaterPlugin

final class NativeSemverTests: XCTestCase {
    func testZeroPaddedCoreEquality() throws {
        XCTAssertEqual(try NativeSemver("1.0"), try NativeSemver("1.0.0"))
    }

    func testReleaseGreaterThanPrerelease() throws {
        XCTAssertGreaterThan(try NativeSemver("1.0.0"), try NativeSemver("1.0.0-beta.1"))
        XCTAssertGreaterThan(try NativeSemver("2.0.0"), try NativeSemver("2.0.0-beta"))
    }

    func testPrereleaseNumericIdentifiersCompareNumerically() throws {
        XCTAssertLessThan(try NativeSemver("1.0.0-beta.2"), try NativeSemver("1.0.0-beta.10"))
        XCTAssertLessThan(try NativeSemver("1.0.0-1"), try NativeSemver("1.0.0-alpha"))
        XCTAssertLessThan(try NativeSemver("1.0.0-alpha.1"), try NativeSemver("1.0.0-alpha.beta"))
    }

    func testBuildMetadataIgnored() throws {
        XCTAssertEqual(try NativeSemver("2.0.0"), try NativeSemver("2.0.0+build.1"))
    }

    func testUnderscoreSeparatesNumericCoreComponents() throws {
        XCTAssertEqual(try NativeSemver("1.2_3"), try NativeSemver("1.2.3"))
        XCTAssertGreaterThan(try NativeSemver("1.2_3"), try NativeSemver("1.2"))
    }

    func testOversizedNumericComponentSaturates() throws {
        // 2^64 == 18446744073709551616 overflows UInt64 and must saturate, not be omitted.
        let oversized = try NativeSemver("18446744073709551616")
        let maxRepresentable = try NativeSemver(String(UInt64.max))
        XCTAssertEqual(oversized, maxRepresentable)
    }
}
