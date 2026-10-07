/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import CommonCrypto
import Foundation
import Security
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
        guard let configJson = CapgoCore.jsonString(config) else {
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
                      let json = CapgoCore.jsonString(keys) else {
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
                      let json = CapgoCore.jsonString(reply) else {
                    return nil
                }
                return strdup(json)
            },
            release: { context in
                guard let context else { return }
                Unmanaged<HostBox>.fromOpaque(context).release()
            },
            verify_server_certificate: CapgoEngine.verifyServerCertificateCallback
        )
        guard let handle = capgo_engine_new(configJson, callbacks) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        capgo_engine_free(handle)
    }

    typealias VerifyServerCertificateCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<UInt8>?>?,
        UnsafePointer<Int>?,
        Int,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    /// `verify_server_certificate` host callback: 1 when the system trust store accepts the
    /// DER chain (leaf first) for the server name; otherwise 0 and the reason in `error`.
    static let verifyServerCertificateCallback: VerifyServerCertificateCallback = { _, serverName, certificates, lengths, count, error in
        guard let serverName, let certificates, let lengths, count > 0 else {
            error?.pointee = strdup("Empty certificate chain")
            return 0
        }
        var chain: [Data] = []
        for index in 0..<count {
            guard let certificate = certificates[index], lengths[index] > 0 else {
                error?.pointee = strdup("Invalid certificate in chain")
                return 0
            }
            chain.append(Data(bytes: certificate, count: lengths[index]))
        }
        if let reason = verifyServerCertificate(chain: chain, serverName: String(cString: serverName)) {
            error?.pointee = strdup(reason)
            return 0
        }
        return 1
    }

    /// Evaluates a TLS server chain (DER, leaf first) like URLSession's default handling:
    /// `SecTrust` with the SSL policy for `serverName` against the system trust store
    /// (including user-installed and MDM roots). Returns nil when trusted, else the reason.
    /// `date` overrides the evaluation time (tests only).
    static func verifyServerCertificate(
        chain: [Data],
        serverName: String,
        date: Date? = nil,
        pinnedDomains: [String: Any]? = pinnedDomainsFromInfoPlist()
    ) -> String? {
        var certificates: [SecCertificate] = []
        for der in chain {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                return "Invalid certificate in chain"
            }
            certificates.append(certificate)
        }
        guard !certificates.isEmpty else {
            return "Empty certificate chain"
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return "Cannot evaluate the certificate chain"
        }
        if let date, SecTrustSetVerifyDate(trust, date as CFDate) != errSecSuccess {
            return "Cannot set the evaluation date"
        }
        var failure: CFError?
        guard SecTrustEvaluateWithError(trust, &failure) else {
            return failure.map { ($0 as Error).localizedDescription } ?? "Certificate not trusted"
        }
        let evaluated = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? certificates
        return pinningFailure(
            chain: evaluated.map { SecCertificateCopyData($0) as Data },
            serverName: serverName,
            pinnedDomains: pinnedDomains
        )
    }

    // MARK: - ATS certificate pinning (NSPinnedDomains)

    static func pinnedDomainsFromInfoPlist() -> [String: Any]? {
        let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        return ats?["NSPinnedDomains"] as? [String: Any]
    }

    /// URLSession enforces the app's `NSPinnedDomains`; the engine's client is not URLSession, so
    /// apply the same rule: for a pinned host, the leaf must match one of `NSPinnedLeafIdentities`
    /// and a CA certificate of the evaluated chain one of `NSPinnedCAIdentities` (each list that is
    /// present), by the base64 SHA-256 of the certificate's SubjectPublicKeyInfo. The most specific
    /// matching domain applies. Returns nil when allowed, else the reason.
    static func pinningFailure(chain: [Data], serverName: String, pinnedDomains: [String: Any]?) -> String? {
        guard let pinnedDomains, !pinnedDomains.isEmpty else {
            return nil
        }
        let host = serverName.lowercased()
        let match = pinnedDomains
            .compactMap { domain, value -> (domain: String, settings: [String: Any])? in
                guard let settings = value as? [String: Any] else {
                    return nil
                }
                return (domain.lowercased(), settings)
            }
            .filter { entry in
                host == entry.domain
                    || (entry.settings["NSIncludesSubdomains"] as? Bool == true && host.hasSuffix("." + entry.domain))
            }
            .max { $0.domain.count < $1.domain.count }
        guard let settings = match?.settings else {
            return nil
        }
        func pins(_ key: String) -> Set<String>? {
            guard let value = settings[key] else {
                return nil
            }
            // A present but malformed list pins to nothing (fails closed) instead of disabling the check.
            let identities = value as? [[String: Any]] ?? []
            return Set(identities.compactMap { $0["SPKI-SHA256-BASE64"] as? String })
        }
        let hashes = chain.map { spkiSha256Base64(certificate: $0) }
        if let leafPins = pins("NSPinnedLeafIdentities") {
            guard let leaf = hashes.first, let leafHash = leaf, leafPins.contains(leafHash) else {
                return "Certificate does not match the pinned leaf identities for \(host)"
            }
        }
        if let caPins = pins("NSPinnedCAIdentities") {
            guard hashes.dropFirst().contains(where: { $0.map(caPins.contains) ?? false }) else {
                return "Certificate does not match the pinned CA identities for \(host)"
            }
        }
        return nil
    }

    /// Base64 SHA-256 of the DER SubjectPublicKeyInfo of an X.509 certificate.
    static func spkiSha256Base64(certificate der: Data) -> String? {
        let bytes = [UInt8](der)
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serialNumber,
        // signature, issuer, validity, subject, subjectPublicKeyInfo, ... } ... }
        guard let certificate = derElement(bytes, at: 0), bytes[0] == 0x30,
              let tbs = derElement(bytes, at: certificate.contentStart), bytes[certificate.contentStart] == 0x30 else {
            return nil
        }
        var offset = tbs.contentStart
        if bytes.indices.contains(offset), bytes[offset] == 0xA0, let version = derElement(bytes, at: offset) {
            offset = version.end
        }
        // serialNumber, signature, issuer, validity, subject
        for _ in 0..<5 {
            guard let element = derElement(bytes, at: offset) else {
                return nil
            }
            offset = element.end
        }
        guard bytes.indices.contains(offset), bytes[offset] == 0x30, let spki = derElement(bytes, at: offset),
              spki.end <= tbs.end else {
            return nil
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let slice = Array(bytes[offset..<spki.end])
        _ = CC_SHA256(slice, CC_LONG(slice.count), &digest)
        return Data(digest).base64EncodedString()
    }

    /// One DER TLV at `offset`: where its content starts and where it ends.
    private static func derElement(_ bytes: [UInt8], at offset: Int) -> (contentStart: Int, end: Int)? {
        guard offset + 1 < bytes.count else {
            return nil
        }
        var index = offset + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else {
                return nil
            }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }
        let end = index + length
        guard end <= bytes.count else {
            return nil
        }
        return (index, end)
    }

    private static func box(_ context: UnsafeMutableRawPointer) -> HostBox {
        Unmanaged<HostBox>.fromOpaque(context).takeUnretainedValue()
    }

    /// Runs an engine operation (blocking). Returns the JSON value (object, array or NSNull).
    func callValue(_ operation: String, _ input: [String: Any?] = [:]) throws -> Any {
        let payload = input.mapValues { $0 ?? NSNull() }
        guard let inputJson = CapgoCore.jsonString(payload) else {
            throw CapgoCore.Failure(code: "invalid_input", message: "Input is not a JSON object")
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
}
