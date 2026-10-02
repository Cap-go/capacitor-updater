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
/// same surface the Android plugin uses through JNI (`resolvePathInside`).
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
}
