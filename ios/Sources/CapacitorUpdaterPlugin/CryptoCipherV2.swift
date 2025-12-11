/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CryptoKit
import BigInt

// V2 Encryption - uses publicKey (modern encryption from main branch)
public struct CryptoCipherV2 {
    private static var logger: Logger!

    public static func setLogger(_ logger: Logger) {
        self.logger = logger
    }

    private static func hexStringToData(_ hex: String) -> Data? {
        var data = Data()
        var hexIterator = hex.makeIterator()
        while let c1 = hexIterator.next(), let c2 = hexIterator.next() {
            guard let byte = UInt8(String([c1, c2]), radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    private static func isHexString(_ str: String) -> Bool {
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return str.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) }
    }

    public static func decryptChecksum(checksum: String, publicKey: String) throws -> String {
        if publicKey.isEmpty {
            logger.info("No encryption set (public key) ignored")
            return checksum
        }
        do {
            // Determine if input is hex or base64 encoded
            // Hex strings only contain 0-9 and a-f, while base64 contains other characters
            let checksumBytes: Data
            let detectedFormat: String
            if isHexString(checksum) {
                // Hex encoded (new format from CLI for plugin versions >= 5.30.0, 6.30.0, 7.30.0)
                guard let hexData = hexStringToData(checksum) else {
                    logger.error("Cannot decode checksum as hex: \(checksum)")
                    throw CustomError.cannotDecode
                }
                checksumBytes = hexData
                detectedFormat = "hex"
            } else {
                // TODO: remove backwards compatibility
                // Base64 encoded (old format for backwards compatibility)
                guard let base64Data = Data(base64Encoded: checksum) else {
                    logger.error("Cannot decode checksum as base64: \(checksum)")
                    throw CustomError.cannotDecode
                }
                checksumBytes = base64Data
                detectedFormat = "base64"
            }
            logger.debug("Received encrypted checksum format: \(detectedFormat) (length: \(checksum.count) chars, \(checksumBytes.count) bytes)")

            if checksumBytes.isEmpty {
                logger.error("Decoded checksum is empty")
                throw CustomError.cannotDecode
            }

            guard let rsaPublicKey = RSAPublicKey.load(rsaPublicKey: publicKey) else {
                logger.error("The public key is not a valid RSA Public key")
                throw CustomError.cannotDecode
            }

            guard let decryptedChecksum = rsaPublicKey.decrypt(data: checksumBytes) else {
                logger.error("decryptChecksum fail")
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            // Return as hex string to match calcChecksum output format
            let result = decryptedChecksum.map { String(format: "%02x", $0) }.joined()

            // Detect checksum algorithm based on length
            let detectedAlgorithm: String
            if decryptedChecksum.count == 32 {
                detectedAlgorithm = "SHA-256"
            } else if decryptedChecksum.count == 4 {
                detectedAlgorithm = "CRC32 (deprecated)"
                logger.error("CRC32 checksum detected. This algorithm is deprecated and no longer supported. Please update your CLI to use SHA-256 checksums.")
            } else {
                detectedAlgorithm = "unknown (\(decryptedChecksum.count) bytes)"
                logger.error("Unknown checksum algorithm detected with \(decryptedChecksum.count) bytes. Expected SHA-256 (32 bytes).")
            }
            logger.debug("Decrypted checksum: \(detectedAlgorithm) hex format (length: \(result.count) chars, \(decryptedChecksum.count) bytes)")
            return result
        } catch {
            logger.error("decryptChecksum fail: \(error.localizedDescription)")
            throw CustomError.cannotDecode
        }
    }

    /// Detect checksum algorithm based on hex string length.
    /// SHA-256 = 64 hex chars (32 bytes)
    /// CRC32 = 8 hex chars (4 bytes)
    public static func detectChecksumAlgorithm(_ hexChecksum: String) -> String {
        if hexChecksum.isEmpty {
            return "empty"
        }
        let len = hexChecksum.count
        if len == 64 {
            return "SHA-256"
        } else if len == 8 {
            return "CRC32 (deprecated)"
        } else {
            return "unknown (\(len) hex chars)"
        }
    }

    /// Log checksum info and warn if deprecated algorithm detected.
    public static func logChecksumInfo(label: String, hexChecksum: String) {
        let algorithm = detectChecksumAlgorithm(hexChecksum)
        logger.debug("\(label): \(algorithm) hex format (length: \(hexChecksum.count) chars)")
        if algorithm.contains("CRC32") {
            logger.error("CRC32 checksum detected. This algorithm is deprecated and no longer supported. Please update your CLI to use SHA-256 checksums.")
        } else if algorithm.contains("unknown") {
            logger.error("Unknown checksum algorithm detected. Expected SHA-256 (64 hex chars) but got \(hexChecksum.count) chars.")
        }
    }

    public static func calcChecksum(filePath: URL) -> String {
        let bufferSize = 1024 * 1024 * 5 // 5 MB
        var sha256 = SHA256()

        do {
            let fileHandle: FileHandle
            do {
                fileHandle = try FileHandle(forReadingFrom: filePath)
            } catch {
                logger.error("Cannot open file for checksum: \(filePath.path) \(error)")
                return ""
            }

            defer {
                do {
                    try fileHandle.close()
                } catch {
                    logger.error("Error closing file: \(error)")
                }
            }

            while autoreleasepool(invoking: {
                let fileData: Data
                do {
                    if #available(iOS 13.4, *) {
                        fileData = try fileHandle.read(upToCount: bufferSize) ?? Data()
                    } else {
                        fileData = fileHandle.readData(ofLength: bufferSize)
                    }
                } catch {
                    logger.error("Error reading file: \(error)")
                    return false
                }

                if fileData.count > 0 {
                    sha256.update(data: fileData)
                    return true // Continue
                } else {
                    return false // End of file
                }
            }) {}

            let digest = sha256.finalize()
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            logger.error("Cannot get checksum: \(filePath.path) \(error)")
            return ""
        }
    }

    public static func decryptFile(filePath: URL, publicKey: String, sessionKey: String, version: String) throws {
        if publicKey.isEmpty || sessionKey.isEmpty || sessionKey.components(separatedBy: ":").count != 2 {
            logger.info("Encryption not set, no public key or session, ignored")
            return
        }

        if !publicKey.hasPrefix("-----BEGIN RSA PUBLIC KEY-----") {
            logger.error("The public key is not a valid RSA Public key")
            return
        }

        do {
            guard let rsaPublicKey = RSAPublicKey.load(rsaPublicKey: publicKey) else {
                logger.error("The public key is not a valid RSA Public key")
                throw CustomError.cannotDecode
            }

            let sessionKeyComponents = sessionKey.components(separatedBy: ":")
            let ivBase64 = sessionKeyComponents[0]
            let encryptedKeyBase64 = sessionKeyComponents[1]

            guard let ivData = Data(base64Encoded: ivBase64) else {
                logger.error("Cannot decode sessionKey IV \(ivBase64)")
                throw CustomError.cannotDecode
            }

            if ivData.count != 16 {
                logger.error("IV data has invalid length: \(ivData.count), expected 16")
                throw CustomError.cannotDecode
            }

            guard let sessionKeyDataEncrypted = Data(base64Encoded: encryptedKeyBase64) else {
                logger.error("Cannot decode sessionKey data \(encryptedKeyBase64)")
                throw NSError(domain: "Invalid session key data", code: 1, userInfo: nil)
            }

            guard let sessionKeyDataDecrypted = rsaPublicKey.decrypt(data: sessionKeyDataEncrypted) else {
                logger.error("Failed to decrypt session key data")
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            if sessionKeyDataDecrypted.count != 16 {
                logger.error("Decrypted session key has invalid length: \(sessionKeyDataDecrypted.count), expected 16")
                throw NSError(domain: "Invalid decrypted session key", code: 5, userInfo: nil)
            }

            let aesPrivateKey = AES128Key(iv: ivData, aes128Key: sessionKeyDataDecrypted, logger: logger)

            let encryptedData: Data
            do {
                encryptedData = try Data(contentsOf: filePath)
            } catch {
                logger.error("Failed to read encrypted data: \(error)")
                throw NSError(domain: "Failed to read encrypted data", code: 3, userInfo: nil)
            }

            if encryptedData.isEmpty {
                logger.error("Encrypted file data is empty")
                throw NSError(domain: "Empty encrypted data", code: 6, userInfo: nil)
            }

            guard let decryptedData = aesPrivateKey.decrypt(data: encryptedData) else {
                logger.error("Failed to decrypt data")
                throw NSError(domain: "Failed to decrypt data", code: 4, userInfo: nil)
            }

            if decryptedData.isEmpty {
                logger.error("Decrypted data is empty")
                throw NSError(domain: "Empty decrypted data", code: 7, userInfo: nil)
            }

            do {
                try decryptedData.write(to: filePath, options: .atomic)
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    logger.error("File was not created after write")
                    throw NSError(domain: "File write failed", code: 8, userInfo: nil)
                }
            } catch {
                logger.error("Error writing decrypted file: \(error)")
                throw error
            }

        } catch {
            logger.error("decryptFile fail")
            throw CustomError.cannotDecode
        }
    }
}
