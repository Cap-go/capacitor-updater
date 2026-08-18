import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

final class RsaContractTests: XCTestCase {
    private static let contract: [String: Any] = {
        do {
            let data = try Data(contentsOf: contractFileURL())
            let value = try JSONSerialization.jsonObject(with: data)
            guard let contract = value as? [String: Any] else {
                throw ContractError.invalidRoot
            }
            return contract
        } catch {
            XCTFail("Unable to load RSA contract fixture: \(error)")
            return [:]
        }
    }()

    private enum ContractError: Error {
        case missingFixture
        case invalidRoot
        case invalidCases(String)
        case invalidCase(String)
    }

    override class func setUp() {
        super.setUp()
        CryptoCipher.setLogger(Logger(withTag: "RsaContractTests", options: Logger.Options(level: .silent)))
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
                    .appendingPathComponent("crypto-rsa.json")
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

    private func string(_ source: [String: Any], _ key: String, id: String) throws -> String {
        guard let value = source[key] as? String else {
            throw ContractError.invalidCase("\(id).\(key)")
        }
        return value
    }

    private func bool(_ source: [String: Any], _ key: String, id: String) throws -> Bool {
        guard let value = source[key] as? Bool else {
            throw ContractError.invalidCase("\(id).\(key)")
        }
        return value
    }

    private func fixturePublicKey() throws -> String {
        if let key = Self.contract["publicKeyPem"] as? String {
            return key
        }
        throw ContractError.invalidRoot
    }

    private func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var iterator = hex.makeIterator()
        while let char1 = iterator.next(), let char2 = iterator.next() {
            guard let byte = UInt8(String([char1, char2]), radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    private func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testRsaPublicDecryptMatchesNativeContract() throws {
        let publicKey = try fixturePublicKey()
        guard let rsaPublicKey = RSAPublicKey.load(rsaPublicKey: publicKey) else {
            XCTFail("Fixture public key must load")
            return
        }

        for testCase in try contractCases("rsaPublicDecrypt") {
            let id = try string(testCase, "id", id: "rsaPublicDecrypt")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)
            let ciphertextHex = try string(input, "ciphertextHex", id: id)
            let expectedPlaintextHex = try string(expect, "plaintextHex", id: id)

            guard let ciphertext = hexToData(ciphertextHex) else {
                XCTFail("\(id): invalid ciphertext hex")
                continue
            }

            guard let decrypted = rsaPublicKey.decrypt(data: ciphertext) else {
                XCTFail("\(id): RSA public decrypt returned nil")
                continue
            }

            XCTAssertEqual(dataToHex(decrypted), expectedPlaintextHex, id)
        }
    }

    func testDecryptChecksumMatchesNativeContract() throws {
        let publicKey = try fixturePublicKey()

        for testCase in try contractCases("decryptChecksum") {
            let id = try string(testCase, "id", id: "decryptChecksum")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)
            let checksumHex = try string(input, "checksumHex", id: id)
            let expectedDecryptedHex = try string(expect, "decryptedHex", id: id)

            let result = try CryptoCipher.decryptChecksum(checksum: checksumHex, publicKey: publicKey)
            XCTAssertEqual(result, expectedDecryptedHex, id)
        }
    }

    func testDecryptChecksumInvalidMatchesNativeContract() throws {
        let publicKey = try fixturePublicKey()

        for testCase in try contractCases("decryptChecksumInvalid") {
            let id = try string(testCase, "id", id: "decryptChecksumInvalid")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)
            let checksumHex = try string(input, "checksumHex", id: id)
            let shouldThrow = try bool(expect, "throws", id: id)

            if shouldThrow {
                XCTAssertThrowsError(
                    try CryptoCipher.decryptChecksum(checksum: checksumHex, publicKey: publicKey),
                    id
                )
            }
        }
    }

    func testCalcKeyIdMatchesNativeContract() throws {
        for testCase in try contractCases("calcKeyId") {
            let id = try string(testCase, "id", id: "calcKeyId")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)
            let publicKey = try string(input, "publicKeyPem", id: id)
            let expectedKeyId = try string(expect, "keyId", id: id)

            XCTAssertEqual(CryptoCipher.calcKeyId(publicKey: publicKey), expectedKeyId, id)
        }
    }

    func testRsaPublicKeyLoadMatchesNativeContract() throws {
        for testCase in try contractCases("rsaPublicKeyLoad") {
            let id = try string(testCase, "id", id: "rsaPublicKeyLoad")
            let input = try dictionary(testCase, "input", id: id)
            let expect = try dictionary(testCase, "expect", id: id)
            let publicKey = try string(input, "publicKeyPem", id: id)
            let shouldLoad = try bool(expect, "loads", id: id)

            let loaded = RSAPublicKey.load(rsaPublicKey: publicKey) != nil
            XCTAssertEqual(loaded, shouldLoad, id)
        }
    }
}
