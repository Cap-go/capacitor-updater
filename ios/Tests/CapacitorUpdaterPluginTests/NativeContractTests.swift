import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

final class NativeContractTests: XCTestCase {
    private static let contract: [String: Any] = {
        do {
            let data = try Data(contentsOf: contractFileURL())
            let value = try JSONSerialization.jsonObject(with: data)
            guard let contract = value as? [String: Any] else {
                throw ContractError.invalidRoot
            }
            return contract
        } catch {
            XCTFail("Unable to load native contract fixture: \(error)")
            return [:]
        }
    }()

    private enum ContractError: Error {
        case missingFixture
        case invalidRoot
        case invalidCases(String)
        case invalidCase(String)
    }

    private static func contractFileURL() throws -> URL {
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
                    .appendingPathComponent("core.json")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                current.deleteLastPathComponent()
            }
        }
        throw ContractError.missingFixture
    }

    private func contractCases(_ key: String) throws -> [[String: Any]] {
        guard let cases = Self.contract[key] as? [[String: Any]] else {
            throw ContractError.invalidCases(key)
        }
        return cases
    }

    private func dictionary(_ source: [String: Any], _ key: String, id: String) throws -> [String: Any] {
        guard let value = source[key] as? [String: Any] else {
            throw ContractError.invalidCase("\(id).\(key)")
        }
        return value
    }

    private func int(_ source: [String: Any], _ key: String, id: String) throws -> Int {
        guard let value = source[key] as? NSNumber else {
            throw ContractError.invalidCase("\(id).\(key)")
        }
        return value.intValue
    }

    private func bool(_ source: [String: Any], _ key: String, id: String) throws -> Bool {
        guard let value = source[key] as? Bool else {
            throw ContractError.invalidCase("\(id).\(key)")
        }
        return value
    }

    private func string(_ source: [String: Any], _ key: String, id: String) throws -> String {
        guard let value = source[key] as? String else {
            throw ContractError.invalidCase("\(id).\(key)")
        }
        return value
    }

    private func optionalString(_ source: [String: Any], _ key: String) -> String? {
        guard let value = source[key], !(value is NSNull) else {
            return nil
        }
        return value as? String
    }

    func testPeriodCheckDelayMatchesNativeContract() throws {
        for testCase in try contractCases("periodCheckDelay") {
            let id = try string(testCase, "id", id: "periodCheckDelay")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)

            XCTAssertEqual(
                CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(try int(input, "seconds", id: id)),
                try int(expect, "normalizedSeconds", id: id),
                id
            )
        }
    }

    func testOnLaunchDirectUpdateConsumptionMatchesNativeContract() throws {
        for testCase in try contractCases("onLaunchDirectUpdateConsumption") {
            let id = try string(testCase, "id", id: "onLaunchDirectUpdateConsumption")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)

            XCTAssertEqual(
                CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(
                    directUpdateMode: try string(input, "mode", id: id),
                    plannedDirectUpdate: try bool(input, "plannedDirectUpdate", id: id)
                ),
                try bool(expect, "consume", id: id),
                id
            )
        }
    }

    func testUpdateResponseKindMatchesNativeContract() throws {
        for testCase in try contractCases("updateResponseKind") {
            let id = try string(testCase, "id", id: "updateResponseKind")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)

            XCTAssertEqual(
                CapacitorUpdaterPlugin.normalizedUpdateResponseKind(kind: optionalString(input, "kind")),
                try string(expect, "kind", id: id),
                id
            )
        }
    }
}
