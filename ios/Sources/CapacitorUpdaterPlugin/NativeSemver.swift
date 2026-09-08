import Foundation

/// Lightweight semver-style comparator for native app version strings.
/// Replaces the third-party Version dependency for delay-update checks.
public struct NativeSemver: Comparable, CustomStringConvertible {
    private let original: String
    private let numericParts: [Int]

    public init(_ version: String) throws {
        guard !version.isEmpty else {
            throw NativeSemverError.empty
        }
        let parts = Self.parseNumericParts(version)
        guard !parts.isEmpty else {
            throw NativeSemverError.noNumericComponents(version)
        }
        self.original = version
        self.numericParts = parts
    }

    public var description: String {
        original
    }

    public static func < (lhs: NativeSemver, rhs: NativeSemver) -> Bool {
        let maxCount = max(lhs.numericParts.count, rhs.numericParts.count)
        for index in 0..<maxCount {
            let left = index < lhs.numericParts.count ? lhs.numericParts[index] : 0
            let right = index < rhs.numericParts.count ? rhs.numericParts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    private static func parseNumericParts(_ version: String) -> [Int] {
        var parts: [Int] = []
        for segment in version.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" || $0 == "_" }) {
            guard !segment.isEmpty else {
                continue
            }
            var end = 0
            while end < segment.count {
                let scalar = segment[segment.index(segment.startIndex, offsetBy: end)]
                if !scalar.isNumber {
                    break
                }
                end += 1
            }
            if end > 0, let value = Int(segment.prefix(end)) {
                parts.append(value)
            }
        }
        return parts
    }
}

public enum NativeSemverError: Error {
    case empty
    case noNumericComponents(String)
}
