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

    func testUnicodeNumericPrereleaseIsNotNumericIdentifier() throws {
        // Superscript ² is Unicode numeric (No) but not an ASCII digit; treat as non-numeric.
        // With Character.isNumber, ² would be numeric and precede "alpha"; ASCII-only keeps lexical order.
        XCTAssertLessThan(try NativeSemver("1.0.0-alpha"), try NativeSemver("1.0.0-²"))
        XCTAssertLessThan(try NativeSemver("1.0.0-1"), try NativeSemver("1.0.0-²"))
    }

    func testUnicodeDigitsInCoreAreNotParsedAsNumeric() throws {
        // Pure Unicode digits yield no ASCII numeric components.
        XCTAssertThrowsError(try NativeSemver("١٢٣"))
        // Leading Arabic-Indic digit stops the digit run; trailing ASCII digits still parse.
        let mixed = try NativeSemver("1١.2.3")
        XCTAssertEqual(mixed, try NativeSemver("1.2.3"))
    }
}
