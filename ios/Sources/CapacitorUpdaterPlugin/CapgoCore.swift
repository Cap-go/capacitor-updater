/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CapgoUpdaterCore

/// Swift binding for the shared Rust updater core (`core/`).
///
/// Every call is `operation name + JSON object in -> JSON object out`, the
/// same surface the Android plugin uses through JNI. Operation names and
/// payloads are pinned by `native-contract-tests/`.
enum CapgoCore {
    struct Failure: Error, CustomStringConvertible {
        let code: String
        let message: String

        var description: String {
            "\(code): \(message)"
        }
    }

    /// Runs a core operation. `nil` input values are sent as JSON `null`.
    static func call(_ operation: String, _ input: [String: Any?] = [:]) throws -> [String: Any] {
        let payload = input.mapValues { $0 ?? NSNull() }
        let inputData = try JSONSerialization.data(withJSONObject: payload)
        guard let inputJson = String(bytes: inputData, encoding: .utf8) else {
            throw Failure(code: "invalid_input", message: "Input is not UTF-8 JSON")
        }

        guard let raw = capgo_core_call(operation, inputJson) else {
            throw Failure(code: "internal", message: "Core returned no result")
        }
        defer {
            capgo_core_free(raw)
        }
        let output = Data(bytes: raw, count: strlen(raw))
        guard let envelope = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw Failure(code: "internal", message: "Core returned invalid JSON")
        }
        if envelope["ok"] as? Bool == true {
            return envelope["value"] as? [String: Any] ?? [:]
        }
        let error = envelope["error"] as? [String: Any]
        throw Failure(
            code: error?["code"] as? String ?? "internal",
            message: error?["message"] as? String ?? "Unknown core error"
        )
    }

    /// Operations that cannot fail for well-formed input. A failure here is a
    /// binding bug: it asserts in debug builds and returns `fallback` in release.
    static func value<T>(_ operation: String, _ input: [String: Any?], _ key: String, fallback: T) -> T {
        do {
            if let value = try call(operation, input)[key] as? T {
                return value
            }
            assertionFailure("Capgo core \(operation) returned no `\(key)`")
        } catch {
            assertionFailure("Capgo core \(operation) failed: \(error)")
        }
        return fallback
    }

    static func bool(_ operation: String, _ input: [String: Any?], _ key: String, fallback: Bool = false) -> Bool {
        value(operation, input, key, fallback: fallback)
    }

    static func string(_ operation: String, _ input: [String: Any?], _ key: String, fallback: String = "") -> String {
        value(operation, input, key, fallback: fallback)
    }

    static func int(_ operation: String, _ input: [String: Any?], _ key: String, fallback: Int = 0) -> Int {
        (value(operation, input, key, fallback: NSNumber(value: fallback)) as NSNumber).intValue
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
}
