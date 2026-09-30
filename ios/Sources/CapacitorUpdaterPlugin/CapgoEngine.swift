/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CapgoUpdaterCore

/// Platform services the Rust engine calls back into, from any thread.
protocol CapgoEngineHost: AnyObject {
    func engineLog(level: Int32, message: String)
    func engineKvGet(_ key: String) -> String?
    func engineKvSet(_ key: String, _ value: String?)
    func engineKvKeys() -> [String]
    func engineEmit(_ event: String, _ payload: [String: Any])
    /// Platform hook (`applyBundle`, `splash`, `backgroundTask`, ...); nil keeps the engine default.
    func engineHook(_ name: String, _ payload: [String: Any]) -> [String: Any]?
}

/// Swift handle on a Rust updater engine (`core/src/engine`). Thread-safe.
final class CapgoEngine {
    private let handle: OpaquePointer

    /// Boxes the host for the C callbacks; weak so the engine never keeps the updater alive.
    private final class HostBox {
        weak var host: CapgoEngineHost?
        init(_ host: CapgoEngineHost) {
            self.host = host
        }
    }

    init?(config: [String: Any], host: CapgoEngineHost) {
        guard let configData = try? JSONSerialization.data(withJSONObject: config),
              let configJson = String(bytes: configData, encoding: .utf8) else {
            return nil
        }
        let context = Unmanaged.passRetained(HostBox(host)).toOpaque()
        let callbacks = CapgoHostCallbacks(
            context: context,
            log: { context, level, message in
                guard let context, let message else { return }
                CapgoEngine.box(context).host?.engineLog(level: level, message: String(cString: message))
            },
            kv_get: { context, key in
                guard let context, let key,
                      let value = CapgoEngine.box(context).host?.engineKvGet(String(cString: key)) else {
                    return nil
                }
                return strdup(value)
            },
            kv_set: { context, key, value in
                guard let context, let key else { return }
                CapgoEngine.box(context).host?.engineKvSet(String(cString: key), value.map { String(cString: $0) })
            },
            kv_keys: { context in
                guard let context,
                      let keys = CapgoEngine.box(context).host?.engineKvKeys(),
                      let data = try? JSONSerialization.data(withJSONObject: keys),
                      let json = String(bytes: data, encoding: .utf8) else {
                    return nil
                }
                return strdup(json)
            },
            emit: { context, event, payload in
                guard let context, let event, let payload else { return }
                let data = Data(bytes: payload, count: strlen(payload))
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                CapgoEngine.box(context).host?.engineEmit(String(cString: event), object)
            },
            free_string: { _, value in
                free(value)
            },
            hook: { context, name, payload in
                guard let context, let name else { return nil }
                let object = payload.flatMap { raw in
                    (try? JSONSerialization.jsonObject(with: Data(bytes: raw, count: strlen(raw)))) as? [String: Any]
                } ?? [:]
                guard let reply = CapgoEngine.box(context).host?.engineHook(String(cString: name), object),
                      let data = try? JSONSerialization.data(withJSONObject: reply),
                      let json = String(bytes: data, encoding: .utf8) else {
                    return nil
                }
                return strdup(json)
            },
            release: { context in
                guard let context else { return }
                Unmanaged<HostBox>.fromOpaque(context).release()
            }
        )
        guard let handle = capgo_engine_new(configJson, callbacks) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        capgo_engine_free(handle)
    }

    private static func box(_ context: UnsafeMutableRawPointer) -> HostBox {
        Unmanaged<HostBox>.fromOpaque(context).takeUnretainedValue()
    }

    /// Runs an engine operation (blocking). Returns the JSON value (object, array or NSNull).
    func callValue(_ operation: String, _ input: [String: Any?] = [:]) throws -> Any {
        let payload = input.mapValues { $0 ?? NSNull() }
        let inputData = try JSONSerialization.data(withJSONObject: payload)
        guard let inputJson = String(bytes: inputData, encoding: .utf8) else {
            throw CapgoCore.Failure(code: "invalid_input", message: "Input is not UTF-8 JSON")
        }
        // Keep this wrapper alive for the whole native call: its deinit frees the engine.
        let result: UnsafeMutablePointer<CChar>? = withExtendedLifetime(self) {
            capgo_engine_call(handle, operation, inputJson)
        }
        guard let raw = result else {
            throw CapgoCore.Failure(code: "internal", message: "Engine returned no result")
        }
        defer {
            capgo_core_free(raw)
        }
        let output = Data(bytes: raw, count: strlen(raw))
        guard let envelope = try JSONSerialization.jsonObject(with: output, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw CapgoCore.Failure(code: "internal", message: "Engine returned invalid JSON")
        }
        if envelope["ok"] as? Bool == true {
            return envelope["value"] ?? NSNull()
        }
        let error = envelope["error"] as? [String: Any]
        throw CapgoCore.Failure(
            code: error?["code"] as? String ?? "internal",
            message: error?["message"] as? String ?? "Unknown engine error"
        )
    }

    func call(_ operation: String, _ input: [String: Any?] = [:]) throws -> [String: Any] {
        try callValue(operation, input) as? [String: Any] ?? [:]
    }

    /// Operations that cannot fail on well-formed input: a failure is a binding bug.
    func callUnchecked(_ operation: String, _ input: [String: Any?] = [:]) -> [String: Any] {
        do {
            return try call(operation, input)
        } catch {
            assertionFailure("Capgo engine \(operation) failed: \(error)")
            return [:]
        }
    }

    func callValueUnchecked(_ operation: String, _ input: [String: Any?] = [:]) -> Any {
        do {
            return try callValue(operation, input)
        } catch {
            assertionFailure("Capgo engine \(operation) failed: \(error)")
            return NSNull()
        }
    }
}
