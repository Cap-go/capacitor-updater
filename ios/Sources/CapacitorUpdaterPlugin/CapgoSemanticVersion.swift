/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// Minimal version value used for native version comparisons.
///
/// Parsing and ordering intentionally mirror the lenient parser of the `Version` package
/// (mrackwitz/Version 0.8.0) that this type replaces, so existing comparisons keep the same results:
/// - `MAJOR[.MINOR[.PATCH]][-PRERELEASE][+BUILD]`, numeric components are ASCII digits (leading zeros allowed).
/// - Missing minor/patch compare as `0`.
/// - A version with a prerelease is lower than the same version without one.
/// - Prerelease identifiers are compared dot by dot: numerically when both are digits, lexically otherwise.
/// - Build metadata is ignored for equality and ordering.
public struct CapgoSemanticVersion: Comparable, Hashable, CustomStringConvertible {
    public enum ParseError: Error {
        case invalidComponents
        case invalidMajorComponent
        case invalidMinorComponent
        case invalidPatchComponent
    }

    public let major: Int
    public let minor: Int?
    public let patch: Int?
    public let prerelease: String?
    public let build: String?

    public var canonicalMinor: Int { minor ?? 0 }
    public var canonicalPatch: Int { patch ?? 0 }

    // Same pattern as the lenient `Version` parser (including its build group quirk: no dots in build metadata).
    private static let versionPattern =
        "\\A([0-9]+)(?:\\.([0-9]+))?(?:\\.([0-9]+))?(?:-([0-9A-Za-z-.]+))?(?:\\+([0-9A-Za-z-]+))??\\z"
    private static let versionRegex = try? NSRegularExpression(pattern: versionPattern)

    public init(major: Int, minor: Int? = nil, patch: Int? = nil, prerelease: String? = nil, build: String? = nil) {
        self.major = max(0, major)
        self.minor = minor.map { max(0, $0) }
        self.patch = patch.map { max(0, $0) }
        self.prerelease = prerelease
        self.build = build
    }

    public init(_ string: String) throws {
        guard let regex = Self.versionRegex else {
            throw ParseError.invalidComponents
        }
        let nsString = string as NSString
        guard let match = regex.firstMatch(in: string, options: [], range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges == 6 else {
            throw ParseError.invalidComponents
        }

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : nsString.substring(with: range)
        }

        guard let major = group(1).flatMap({ Int($0) }) else {
            throw ParseError.invalidMajorComponent
        }
        let minorComponent = group(2)
        let minor = minorComponent.flatMap { Int($0) }
        if minorComponent != nil && minor == nil {
            throw ParseError.invalidMinorComponent
        }
        let patchComponent = group(3)
        let patch = patchComponent.flatMap { Int($0) }
        if patchComponent != nil && patch == nil {
            throw ParseError.invalidPatchComponent
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = group(4)
        self.build = group(5)
    }

    public var description: String {
        var result = "\(major)"
        if let minor {
            result += ".\(minor)"
        }
        if let patch {
            result += ".\(patch)"
        }
        if let prerelease {
            result += "-\(prerelease)"
        }
        if let build {
            result += "+\(build)"
        }
        return result
    }

    public static func == (lhs: CapgoSemanticVersion, rhs: CapgoSemanticVersion) -> Bool {
        return lhs.major == rhs.major
            && lhs.canonicalMinor == rhs.canonicalMinor
            && lhs.canonicalPatch == rhs.canonicalPatch
            && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(canonicalMinor)
        hasher.combine(canonicalPatch)
        hasher.combine(prerelease)
    }

    public static func < (lhs: CapgoSemanticVersion, rhs: CapgoSemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.canonicalMinor != rhs.canonicalMinor {
            return lhs.canonicalMinor < rhs.canonicalMinor
        }
        if lhs.canonicalPatch != rhs.canonicalPatch {
            return lhs.canonicalPatch < rhs.canonicalPatch
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (.some, .none):
            return true
        case (.none, .some), (.none, .none):
            return false
        case let (.some(lpre), .some(rpre)):
            return comparePrerelease(lpre, rpre) == .orderedAscending
        }
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        return !value.isEmpty && value.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsComponents = lhs.components(separatedBy: ".")
        let rhsComponents = rhs.components(separatedBy: ".")
        if let (left, right) = zip(lhsComponents, rhsComponents).first(where: { $0.0 != $0.1 }) {
            if isNumericIdentifier(left) && isNumericIdentifier(right) {
                let leftValue = Int(left) ?? 0
                let rightValue = Int(right) ?? 0
                if leftValue == rightValue {
                    return .orderedSame
                }
                return leftValue < rightValue ? .orderedAscending : .orderedDescending
            }
            if left == right {
                return .orderedSame
            }
            return left < right ? .orderedAscending : .orderedDescending
        }
        if lhsComponents.count != rhsComponents.count {
            return lhsComponents.count < rhsComponents.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}
