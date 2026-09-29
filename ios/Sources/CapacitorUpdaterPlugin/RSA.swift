/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// Capgo v2 uses Node's privateEncrypt with PKCS#1 v1.5 type-1 padding for
/// checksums and session keys. Parsing and recovery run in the shared Rust
/// core so every platform accepts exactly the same keys and signatures.
public struct RSAPublicKey {
    private let pem: String

    /// Returns nil when the PEM is not a usable RSA public key.
    public static func load(rsaPublicKey: String) -> RSAPublicKey? {
        guard CapgoCore.bool("publicKeyValid", ["publicKey": rsaPublicKey], "valid") else {
            return nil
        }
        return RSAPublicKey(pem: rsaPublicKey)
    }

    /// Recovers the payload signed with the private key, or nil when the
    /// block is malformed, has the wrong length or was signed by another key.
    public func decrypt(data: Data) -> Data? {
        let result = try? CapgoCore.call("rsaPublicDecrypt", [
            "publicKey": pem,
            "ciphertextHex": CapgoCore.hex(data)
        ])
        return (result?["plaintextHex"] as? String).flatMap { CapgoCore.data(hex: $0) }
    }

    /// RFC 8017: 00 01, at least eight FF bytes, 00, then the payload.
    static func unpadSignature(_ block: Data, blockSize: Int = 256) -> Data? {
        let result = try? CapgoCore.call("rsaUnpadSignature", [
            "blockHex": CapgoCore.hex(block),
            "blockSize": blockSize
        ])
        return (result?["payloadHex"] as? String).flatMap { CapgoCore.data(hex: $0) }
    }
}
