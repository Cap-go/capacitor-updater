import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// Runs the shared core contract fixtures (policy, security, crypto) through
/// `CoreContractAdapter`, which targets the current Swift implementation.
final class CoreContractTests: XCTestCase {
    private enum ContractError: Error {
        case missingFixture(String)
        case invalidRoot(String)
        case invalidCase(String)
    }

    override func setUp() {
        super.setUp()
        CryptoCipher.setLogger(Logger(withTag: "CoreContractTests", options: Logger.Options(level: .silent)))
    }

    func testPolicyContract() throws {
        try runFixture("policy")
    }

    func testSecurityContract() throws {
        try runFixture("security")
    }

    func testCryptoContract() throws {
        try runFixture("crypto")
    }

    // MARK: - Runner

    private func runFixture(_ name: String) throws {
        let fixture = try Self.loadFixture(name)
        let publicKeyPem = fixture["publicKeyPem"] as? String
        let groups = fixture.filter { $0.value is [Any] }.keys.sorted()
        XCTAssertFalse(groups.isEmpty, "\(name).json has no groups")

        var passed = 0
        var skipped: [String] = []
        for group in groups {
            guard let cases = fixture[group] as? [[String: Any]] else {
                throw ContractError.invalidCase("\(name).\(group) must be an array of cases")
            }
            for testCase in cases {
                guard let id = testCase["id"] as? String,
                      var input = testCase["input"] as? [String: Any],
                      let expect = testCase["expect"] as? [String: Any] else {
                    throw ContractError.invalidCase("\(name).\(group) case is missing id/input/expect")
                }
                if let reason = skipReason(group: group, testCase: testCase, input: input) {
                    skipped.append("\(id) (\(reason))")
                    continue
                }
                // crypto.json: `publicKey: null` means "use the fixture key".
                if let publicKeyPem, input.keys.contains("publicKey"), input["publicKey"] is NSNull {
                    input["publicKey"] = publicKeyPem
                }
                if check(group: group, id: id, input: input, expect: expect) {
                    passed += 1
                }
            }
        }

        print("[CoreContractTests] \(name).json: \(passed) passed, \(skipped.count) skipped")
        for entry in skipped {
            print("[CoreContractTests]   skipped \(entry)")
        }
    }

    private func skipReason(group: String, testCase: [String: Any], input: [String: Any]) -> String? {
        // Every case runs: the plugin is backed by the shared Rust core, so there
        // are no platform divergences left to skip.
        nil
    }

    private func check(group: String, id: String, input: [String: Any], expect: [String: Any]) -> Bool {
        // Error cases are exactly {"error": "<code>"}; remoteError success outputs also carry an `error` key.
        let expectsError = expect.count == 1 && expect["error"] is String
        let output: [String: Any]
        do {
            output = try CoreContractAdapter.run(group: group, input: input)
        } catch let error as CoreContractAdapter.InputError {
            XCTFail("\(id): invalid fixture input: \(error)")
            return false
        } catch {
            if expectsError {
                return true
            }
            XCTFail("\(id): unexpected error \(error), expected \(Self.describe(expect))")
            return false
        }

        if expectsError {
            XCTFail("\(id): expected error \(Self.describe(expect)), got \(Self.describe(output))")
            return false
        }
        guard let normalized = Self.normalize(output) else {
            XCTFail("\(id): adapter output is not JSON serializable: \(output)")
            return false
        }
        guard Self.jsonEqual(normalized, expect) else {
            XCTFail("\(id): expected \(Self.describe(expect)), got \(Self.describe(output))")
            return false
        }
        return true
    }

    // MARK: - JSON helpers

    private static func normalize(_ value: [String: Any]) -> Any? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Deep JSON equality: same keys, explicit nulls, booleans distinct from numbers, numbers compared numerically.
    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (is NSNull, is NSNull):
            return true
        case let (left as [String: Any], right as [String: Any]):
            guard Set(left.keys) == Set(right.keys) else {
                return false
            }
            return left.allSatisfy { key, value in right[key].map { jsonEqual(value, $0) } ?? false }
        case let (left as [Any], right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { jsonEqual($0, $1) }
        case let (left as String, right as String):
            return left == right
        case let (left as NSNumber, right as NSNumber):
            let leftIsBool = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightIsBool = CFGetTypeID(right) == CFBooleanGetTypeID()
            guard leftIsBool == rightIsBool else {
                return false
            }
            return leftIsBool ? left.boolValue == right.boolValue : left.doubleValue == right.doubleValue
        default:
            return false
        }
    }

    private static func describe(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private static func loadFixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: try fixtureURL(name))
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractError.invalidRoot(name)
        }
        return fixture
    }

    private static func fixtureURL(_ name: String) throws -> URL {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            URL(fileURLWithPath: #filePath)
        ]

        for root in roots {
            var current = root
            while current.path != "/" {
                let candidate = current
                    .appendingPathComponent("native-contract-tests")
                    .appendingPathComponent("\(name).json")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                current.deleteLastPathComponent()
            }
        }
        throw ContractError.missingFixture(name)
    }
}
