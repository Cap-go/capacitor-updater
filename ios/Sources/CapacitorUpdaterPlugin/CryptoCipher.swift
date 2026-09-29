/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CryptoKit

/// Bundle crypto entry points. The work (RSA recovery, AES-128-CBC
/// decryption, SHA-256 of files) runs in the shared Rust core; this type keeps
/// the plugin's logging and error surface.
public struct CryptoCipher {
    private static var logger: Logger!

    public static func setLogger(_ logger: Logger) {
        self.logger = logger
    }

    public static func decryptChecksum(checksum: String, publicKey: String) throws -> String {
        if publicKey.isEmpty {
            logger.info("No encryption set (public key) ignored")
            return checksum
        }
        do {
            let result = try CapgoCore.call("decryptChecksum", ["checksum": checksum, "publicKey": publicKey])
            guard let decrypted = result["checksum"] as? String else {
                throw CustomError.cannotDecode
            }
            logChecksumInfo(label: "Decrypted checksum", hexChecksum: decrypted)
            return decrypted
        } catch {
            logger.error("Checksum decryption failed")
            logger.debug("Error: \(error)")
            throw CustomError.cannotDecode
        }
    }

    /// Detect checksum algorithm based on hex string length.
    /// SHA-256 = 64 hex chars (32 bytes)
    /// CRC32 = 8 hex chars (4 bytes)
    public static func detectChecksumAlgorithm(_ hexChecksum: String) -> String {
        CapgoCore.string("checksumAlgorithm", ["checksum": hexChecksum], "algorithm", fallback: "empty")
    }

    /// Log checksum info and warn if deprecated algorithm detected.
    public static func logChecksumInfo(label: String, hexChecksum: String) {
        let algorithm = detectChecksumAlgorithm(hexChecksum)
        logger.debug("\(label): \(algorithm) hex format (length: \(hexChecksum.count) chars)")
        if algorithm.contains("CRC32") {
            logger.error("CRC32 checksum detected - deprecated algorithm")
        } else if algorithm.contains("unknown") {
            logger.error("Unknown checksum algorithm detected")
            logger.debug("Char count: \(hexChecksum.count), Expected: 64 (SHA-256)")
        }
    }

    /// 256 KiB: one size for checksum, copy, and decode.
    /// 64 workers * 256 KiB = 16 MiB for one buffer; AES/Brotli hold two (~32 MiB).
    static let ioBufferBytesValue = 256 * 1024

    static func ioBufferBytes() -> Int {
        return ioBufferBytesValue
    }

    static func checksumBufferBytes() -> Int {
        return ioBufferBytesValue
    }

    static func copyBufferBytes() -> Int {
        return ioBufferBytesValue
    }

    /// Lowercase hex SHA-256 of a file, or "" when it cannot be read.
    public static func calcChecksum(filePath: URL) -> String {
        do {
            let result = try CapgoCore.call("checksumFile", ["path": filePath.path])
            return result["checksum"] as? String ?? ""
        } catch {
            logger.error("Cannot calculate checksum")
            logger.debug("Path: \(filePath.path), Error: \(error)")
            return ""
        }
    }

    /// Incremental SHA-256 for bytes streamed during a download.
    final class RunningChecksum {
        private var sha256 = SHA256()

        func update(_ data: Data) {
            guard !data.isEmpty else {
                return
            }
            sha256.update(data: data)
        }

        func hex() -> String {
            CryptoCipher.hexString(from: sha256)
        }
    }

    static func hexString(from sha256: SHA256) -> String {
        return sha256.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    static func shortPathKey(_ fileName: String) -> String {
        CapgoCore.string("shortPathKey", ["value": fileName], "key")
    }

    public static func isValidSessionKey(_ sessionKey: String) -> Bool {
        CapgoCore.bool("sessionKeyValid", ["sessionKey": sessionKey], "valid")
    }

    /// Decrypts an encrypted bundle in place. No-op when the bundle is not encrypted.
    public static func decryptFile(filePath: URL, publicKey: String, sessionKey: String, version: String) throws {
        let outcome: String
        do {
            let result = try CapgoCore.call("decryptFile", [
                "path": filePath.path,
                "publicKey": publicKey,
                "sessionKey": sessionKey
            ])
            outcome = result["outcome"] as? String ?? ""
        } catch {
            logger.error("File decryption failed")
            logger.debug("Version: \(version), Error: \(error)")
            throw CustomError.cannotDecode
        }
        if outcome == "notEncrypted" {
            logger.info("Encryption not set, no public key or session, ignored")
        }
    }

    /// Get first 20 characters of the public key for identification
    /// Returns 20-character string or empty string if key is invalid/empty
    /// The first 12 chars are always "MIIBCgKCAQEA" for RSA 2048-bit keys,
    /// so the unique part starts at character 13
    public static func calcKeyId(publicKey: String) -> String {
        CapgoCore.string("keyId", ["publicKey": publicKey], "keyId")
    }
}
