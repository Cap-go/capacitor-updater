/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Security

/// Capgo v2 uses Node's privateEncrypt with PKCS#1 v1.5 type-1 padding for
/// checksums and session keys. Recover the signed payload using Apple's RSA
/// implementation, avoiding thousands of unoptimized Swift BigInt operations.
public struct RSAPublicKey {
    private let key: SecKey
    private static let keyLock = NSLock()
    // One public key only: bounded storage, invalid/rotated keys never fall back
    // to a cached key with a different PEM. SecKey is immutable after import.
    private static var cachedKey: (pem: String, key: SecKey)?

    public static func load(rsaPublicKey: String) -> RSAPublicKey? {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cached = cachedKey, cached.pem == rsaPublicKey {
            return RSAPublicKey(key: cached.key)
        }
        let encoded = rsaPublicKey
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: encoded) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyGetBlockSize(key) == 256,
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else {
            return nil
        }
        cachedKey = (rsaPublicKey, key)
        return RSAPublicKey(key: key)
    }

    public func decrypt(data: Data) -> Data? {
        guard data.count == SecKeyGetBlockSize(key) else { return nil }
        // Raw public-key encryption is the same c^e mod n operation as Node's
        // publicDecrypt. Do NOT use encryption PKCS#1 padding here: the recovered
        // block already contains signature (type-1) padding, checked below.
        guard let recovered = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, data as CFData, nil) else {
            return nil
        }
        return Self.unpadSignature(recovered as Data)
    }

    static func unpadSignature(_ block: Data) -> Data? {
        let bytes = [UInt8](block)
        // RFC 8017: 00 01, at least eight FF bytes, 00, then the payload.
        guard bytes.count == 256, bytes[0] == 0, bytes[1] == 1 else { return nil }
        var separator = 2
        while separator < bytes.count && bytes[separator] == 0xff {
            separator += 1
        }
        guard separator >= 10, separator < bytes.count - 1, bytes[separator] == 0 else {
            return nil
        }
        return Data(bytes[(separator + 1)...])
    }
}
