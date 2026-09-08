/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Security
import os.log

/// Capgo v2 uses Node's privateEncrypt with PKCS#1 v1.5 type-1 padding for
/// checksums and session keys. Recover the signed payload using Apple's RSA
/// implementation instead of custom modular exponentiation.
public struct RSAPublicKey {
    private let key: SecKey
    private static let keyLock = NSLock()
    private static let log = OSLog(subsystem: "ee.forgr.capacitor_updater", category: "RSA")
    // One public key only: bounded storage, invalid/rotated keys never fall back
    // to a cached key with different material. SecKey is immutable after import.
    private static var cachedKey: (der: Data, key: SecKey)?

    public static func load(rsaPublicKey: String) -> RSAPublicKey? {
        guard let der = pemToDer(rsaPublicKey) else {
            os_log("RSA key import failed: invalid PEM/base64", log: Self.log, type: .error)
            return nil
        }

        keyLock.lock()
        defer { keyLock.unlock() }
        if let cached = cachedKey, cached.der == der {
            return RSAPublicKey(key: cached.key)
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            os_log(
                "RSA key import failed: %{public}@",
                log: Self.log,
                type: .error,
                String(describing: error?.takeRetainedValue())
            )
            return nil
        }
        guard SecKeyGetBlockSize(key) == 256,
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else { // NOSONAR intentional raw RSA for Node privateEncrypt / Capgo checksum recovery
            os_log(
                "RSA key import failed: unsupported key (Capgo requires RSA-2048 with raw encryption)",
                log: Self.log,
                type: .error
            )
            return nil
        }
        cachedKey = (der, key)
        return RSAPublicKey(key: key)
    }

    public func decrypt(data: Data) -> Data? {
        let blockSize = SecKeyGetBlockSize(key)
        guard data.count == blockSize else { return nil }
        // Raw public-key encryption is the same c^e mod n operation as Node's
        // publicDecrypt. Do NOT use encryption PKCS#1 padding here: the recovered
        // block already contains signature (type-1) padding, checked below.
        var error: Unmanaged<CFError>?
        guard let recovered = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, data as CFData, &error) else { // NOSONAR intentional raw RSA for Node privateEncrypt / Capgo checksum recovery
            os_log(
                "RSA raw recovery failed: %{public}@",
                log: Self.log,
                type: .error,
                String(describing: error?.takeRetainedValue())
            )
            return nil
        }
        return Self.unpadSignature(recovered as Data, blockSize: blockSize)
    }

    static func unpadSignature(_ block: Data, blockSize: Int = 256) -> Data? {
        let bytes = [UInt8](block)
        // RFC 8017: 00 01, at least eight FF bytes, 00, then the payload.
        guard bytes.count == blockSize, bytes[0] == 0, bytes[1] == 1 else { return nil }
        var separator = 2
        while separator < bytes.count && bytes[separator] == 0xff {
            separator += 1
        }
        guard separator >= 10, separator < bytes.count - 1, bytes[separator] == 0 else {
            return nil
        }
        return Data(bytes[(separator + 1)...])
    }

    private static func pemToDer(_ pem: String) -> Data? {
        let encoded = pem
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: encoded)
    }
}
