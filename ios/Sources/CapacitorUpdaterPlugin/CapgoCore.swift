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

    /// JSON text for `object`, or nil when it is not valid JSON. JSONSerialization raises an
    /// Objective-C exception (which Swift cannot catch: the app crashes) on NaN, infinity or a
    /// non-JSON type, so it is checked first. Inside an engine callback that would abort.
    static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// Runs a core operation. `nil` input values are sent as JSON `null`.
    static func call(_ operation: String, _ input: [String: Any?] = [:]) throws -> [String: Any] {
        let payload = input.mapValues { $0 ?? NSNull() }
        guard let inputJson = jsonString(payload) else {
            throw Failure(code: "invalid_input", message: "Input is not a JSON object")
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
