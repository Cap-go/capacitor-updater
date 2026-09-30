import Foundation
@testable import CapacitorUpdaterPlugin

/// Maps a shared core contract operation (`group` + JSON `input`) onto the
/// Swift binding of the Rust core and returns the JSON output object.
///
/// Success returns a dictionary with exactly the keys of the fixture `expect`.
/// Contract errors (`expect: {"error": ...}`) must surface as a thrown error;
/// the error type is not compared here (the Rust contract runner checks codes).
/// Malformed fixture input throws `CoreContractAdapter.InputError`, which the
/// runner always reports as a failure.
enum CoreContractAdapter {
    struct InputError: Error, CustomStringConvertible {
        let description: String
    }

    typealias Operation = (ContractInput) throws -> [String: Any]

    static func run(group: String, input: [String: Any]) throws -> [String: Any] {
        // Policy, HTTP and path rules have no Swift wrapper: the engine and the
        // host call the core directly, so the fixtures run through the binding.
        guard let operation = cryptoOperations[group] else {
            return try CapgoCore.call(group, input.mapValues { $0 as Any? })
        }
        return try operation(ContractInput(values: input))
    }

    // MARK: - crypto.json

    private static let cryptoOperations: [String: Operation] = [
        "sessionKeyValid": { input in
            ["valid": CryptoCipher.isValidSessionKey(try input.string("sessionKey"))]
        },
        "keyId": { input in
            ["keyId": CryptoCipher.calcKeyId(publicKey: try input.string("publicKey"))]
        },
        "publicKeyValid": { input in
            ["valid": RSAPublicKey.load(rsaPublicKey: try input.string("publicKey")) != nil]
        },
        "checksumAlgorithm": { input in
            ["algorithm": CryptoCipher.detectChecksumAlgorithm(try input.string("checksum"))]
        },
        "checksumFile": { input in
            let chunk = try hexData(try input.string("contentHex"))
            let content = Data((0..<max(0, try input.int("repeat"))).flatMap { _ in chunk })
            return ["checksum": try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("checksum-input")
                try content.write(to: file)
                return CryptoCipher.calcChecksum(filePath: file)
            }]
        },
        "decryptChecksum": { input in
            ["checksum": try CryptoCipher.decryptChecksum(
                checksum: try input.string("checksum"),
                publicKey: try input.string("publicKey")
            )]
        },
        "decryptFile": { input in
            let ciphertext = try hexData(try input.string("ciphertextHex"))
            return ["plaintextHex": try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("bundle.zip")
                try ciphertext.write(to: file)
                try CryptoCipher.decryptFile(
                    filePath: file,
                    publicKey: try input.string("publicKey"),
                    sessionKey: try input.string("sessionKey"),
                    version: "core-contract"
                )
                return hexString(try Data(contentsOf: file))
            }]
        }
    ]

    // MARK: - Helpers

    private static func hexData(_ hex: String) throws -> Data {
        let bytes = Array(hex.utf8)
        guard bytes.count.isMultiple(of: 2) else {
            throw InputError(description: "odd-length hex")
        }
        var data = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let pair = String(bytes: bytes[index...index + 1], encoding: .ascii),
                  let byte = UInt8(pair, radix: 16) else {
                throw InputError(description: "invalid hex")
            }
            data.append(byte)
        }
        return data
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        return try body(directory)
    }
}

/// Typed access to a fixture `input` object. JSON `null` maps to Swift `nil`.
struct ContractInput {
    let values: [String: Any]

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String else {
            throw CoreContractAdapter.InputError(description: "\(key) must be a string")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else {
            return nil
        }
        return try string(key)
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw CoreContractAdapter.InputError(description: "\(key) must be a boolean")
        }
        return value.boolValue
    }

    func int(_ key: String) throws -> Int {
        Int(try number(key).int64Value)
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key], !(value is NSNull) else {
            return nil
        }
        return try int(key)
    }

    func double(_ key: String) throws -> Double {
        try number(key).doubleValue
    }

    private func number(_ key: String) throws -> NSNumber {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw CoreContractAdapter.InputError(description: "\(key) must be a number")
        }
        return value
    }
}
