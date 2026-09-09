import Foundation

/// Lightweight semver-style comparator for native app version strings.
/// Replaces the third-party Version dependency for delay-update checks.
public struct NativeSemver: Comparable, CustomStringConvertible, Equatable {
    private let original: String
    private let numericParts: [UInt64]
    private let prerelease: String?

    public static func parseOrDefault(_ version: String?, fallback: String = "0.0.0") -> NativeSemver {
        guard let version, !version.isEmpty else {
            return (try? NativeSemver(fallback)) ?? NativeSemver(fallback: fallback)
        }
        return (try? NativeSemver(version)) ?? NativeSemver(fallback: fallback)
    }

    public init(_ version: String) throws {
        guard !version.isEmpty else {
            throw NativeSemverError.empty
        }
        let core = Self.splitCoreAndPrerelease(version)
        let parts = Self.parseNumericParts(core.core)
        guard !parts.isEmpty else {
            throw NativeSemverError.noNumericComponents(version)
        }
        self.original = version
        self.numericParts = parts
        self.prerelease = core.prerelease
    }

    private init(fallback: String) {
        self.original = fallback
        self.numericParts = [0, 0, 0]
        self.prerelease = nil
    }

    public var description: String {
        original
    }

    public static func == (lhs: NativeSemver, rhs: NativeSemver) -> Bool {
        lhs.compareCoreAndPrerelease(to: rhs) == 0
    }

    public static func < (lhs: NativeSemver, rhs: NativeSemver) -> Bool {
        lhs.compareCoreAndPrerelease(to: rhs) < 0
    }

    private func compareCoreAndPrerelease(to other: NativeSemver) -> Int {
        let maxCount = max(numericParts.count, other.numericParts.count)
        for index in 0..<maxCount {
            let left = index < numericParts.count ? numericParts[index] : 0
            let right = index < other.numericParts.count ? other.numericParts[index] : 0
            if left < right {
                return -1
            }
            if left > right {
                return 1
            }
        }
        switch (prerelease, other.prerelease) {
        case (nil, nil):
            return 0
        case (nil, _):
            return 1
        case (_, nil):
            return -1
        case let (left?, right?):
            return Self.comparePrerelease(left, right)
        }
    }

    private static func comparePrerelease(_ left: String, _ right: String) -> Int {
        let leftIds = left.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rightIds = right.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let maxCount = max(leftIds.count, rightIds.count)
        for index in 0..<maxCount {
            if index >= leftIds.count {
                return -1
            }
            if index >= rightIds.count {
                return 1
            }
            let cmp = comparePrereleaseIdentifier(leftIds[index], rightIds[index])
            if cmp != 0 {
                return cmp
            }
        }
        return 0
    }

    private static func comparePrereleaseIdentifier(_ left: String, _ right: String) -> Int {
        let leftNumeric = isNumericIdentifier(left)
        let rightNumeric = isNumericIdentifier(right)
        if leftNumeric && rightNumeric {
            let leftDigits = stripLeadingZeros(left)
            let rightDigits = stripLeadingZeros(right)
            if leftDigits.count != rightDigits.count {
                return leftDigits.count < rightDigits.count ? -1 : 1
            }
            if leftDigits == rightDigits {
                return 0
            }
            return leftDigits < rightDigits ? -1 : 1
        }
        if leftNumeric {
            return -1
        }
        if rightNumeric {
            return 1
        }
        if left == right {
            return 0
        }
        return left < right ? -1 : 1
    }

    /// SemVer numeric identifiers are ASCII digits only (`0`–`9`), not Unicode Nd/No.
    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private static func isAsciiDigit(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && isAsciiDigit(character.unicodeScalars.first!)
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(isAsciiDigit)
    }

    private static func stripLeadingZeros(_ digits: String) -> String {
        var result = digits
        while result.count > 1 && result.first == "0" {
            result.removeFirst()
        }
        return result
    }

    private static func splitCoreAndPrerelease(_ version: String) -> (core: String, prerelease: String?) {
        var working = version
        if let plusIndex = working.firstIndex(of: "+") {
            working = String(working[..<plusIndex])
        }
        if let dashIndex = working.firstIndex(of: "-") {
            let core = String(working[..<dashIndex])
            let prerelease = String(working[working.index(after: dashIndex)...])
            return (core, prerelease.isEmpty ? nil : prerelease)
        }
        return (working, nil)
    }

    private static func parseNumericParts(_ core: String) -> [UInt64] {
        var parts: [UInt64] = []
        for segment in core.replacingOccurrences(of: "_", with: ".").split(separator: ".", omittingEmptySubsequences: false) {
            guard !segment.isEmpty else {
                continue
            }
            var end = 0
            while end < segment.count {
                let scalar = segment[segment.index(segment.startIndex, offsetBy: end)]
                if !isAsciiDigit(scalar) {
                    break
                }
                end += 1
            }
            if end > 0, let value = parseNumericComponent(String(segment.prefix(end))) {
                parts.append(value)
            }
        }
        return parts
    }

    private static func parseNumericComponent(_ digits: String) -> UInt64? {
        if digits.count > 20 {
            return UInt64.max
        }
        return UInt64(digits) ?? UInt64.max
    }
}

public enum NativeSemverError: Error {
    case empty
    case noNumericComponents(String)
}
