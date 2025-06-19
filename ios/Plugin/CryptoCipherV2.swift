/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CryptoKit
import BigInt

public struct CryptoCipherV2 {

    public static func decryptChecksum(checksum: String, publicKey: String) throws -> String {
        if publicKey.isEmpty {
            print("\(CapacitorUpdater.TAG) No encryption set (public key) ignored")
            return checksum
        }
        do {
            guard let checksumBytes = Data(base64Encoded: checksum) else {
                print("\(CapacitorUpdater.TAG) Cannot decode checksum as base64: \(checksum)")
                throw CustomError.cannotDecode
            }

            if checksumBytes.isEmpty {
                print("\(CapacitorUpdater.TAG) Decoded checksum is empty")
                throw CustomError.cannotDecode
            }

            guard let rsaPublicKey = RSAPublicKey.load(rsaPublicKey: publicKey) else {
                print("\(CapacitorUpdater.TAG) The public key is not a valid RSA Public key")
                throw CustomError.cannotDecode
            }

            guard let decryptedChecksum = rsaPublicKey.decrypt(data: checksumBytes) else {
                print("\(CapacitorUpdater.TAG) decryptChecksum fail")
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            return decryptedChecksum.base64EncodedString()
        } catch {
            print("\(CapacitorUpdater.TAG) decryptChecksum fail: \(error.localizedDescription)")
            throw CustomError.cannotDecode
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
                print("\(CapacitorUpdater.TAG) Cannot open file for checksum: \(filePath.path)", error)
                return ""
            }

            defer {
                do {
                    try fileHandle.close()
                } catch {
                    print("\(CapacitorUpdater.TAG) Error closing file: \(error)")
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
                    print("\(CapacitorUpdater.TAG) Error reading file: \(error)")
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
            print("\(CapacitorUpdater.TAG) Cannot get checksum: \(filePath.path)", error)
            return ""
        }
    }

    public static func decryptFile(filePath: URL, publicKey: String, sessionKey: String, version: String) throws {
        if publicKey.isEmpty || sessionKey.isEmpty || sessionKey.components(separatedBy: ":").count != 2 {
            print("\(CapacitorUpdater.TAG) Encryption not set, no public key or seesion, ignored")
            return
        }

        if !publicKey.hasPrefix("-----BEGIN RSA PUBLIC KEY-----") {
            print("\(CapacitorUpdater.TAG) The public key is not a valid RSA Public key")
            return
        }

        do {
            guard let rsaPublicKey = RSAPublicKey.load(rsaPublicKey: publicKey) else {
                print("\(CapacitorUpdater.TAG) The public key is not a valid RSA Public key")
                throw CustomError.cannotDecode
            }

            let sessionKeyComponents = sessionKey.components(separatedBy: ":")
            let ivBase64 = sessionKeyComponents[0]
            let encryptedKeyBase64 = sessionKeyComponents[1]

            guard let ivData = Data(base64Encoded: ivBase64) else {
                print("\(CapacitorUpdater.TAG) Cannot decode sessionKey IV", ivBase64)
                throw CustomError.cannotDecode
            }

            if ivData.count != 16 {
                print("\(CapacitorUpdater.TAG) IV data has invalid length: \(ivData.count), expected 16")
                throw CustomError.cannotDecode
            }

            guard let sessionKeyDataEncrypted = Data(base64Encoded: encryptedKeyBase64) else {
                print("\(CapacitorUpdater.TAG) Cannot decode sessionKey data", encryptedKeyBase64)
                throw NSError(domain: "Invalid session key data", code: 1, userInfo: nil)
            }

            guard let sessionKeyDataDecrypted = rsaPublicKey.decrypt(data: sessionKeyDataEncrypted) else {
                print("\(CapacitorUpdater.TAG) Failed to decrypt session key data")
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            if sessionKeyDataDecrypted.count != 16 {
                print("\(CapacitorUpdater.TAG) Decrypted session key has invalid length: \(sessionKeyDataDecrypted.count), expected 16")
                throw NSError(domain: "Invalid decrypted session key", code: 5, userInfo: nil)
            }

            let aesPrivateKey = AES128Key(iv: ivData, aes128Key: sessionKeyDataDecrypted)

            let encryptedData: Data
            do {
                encryptedData = try Data(contentsOf: filePath)
            } catch {
                print("\(CapacitorUpdater.TAG) Failed to read encrypted data: \(error)")
                throw NSError(domain: "Failed to read encrypted data", code: 3, userInfo: nil)
            }

            if encryptedData.isEmpty {
                print("\(CapacitorUpdater.TAG) Encrypted file data is empty")
                throw NSError(domain: "Empty encrypted data", code: 6, userInfo: nil)
            }

            guard let decryptedData = aesPrivateKey.decrypt(data: encryptedData) else {
                print("\(CapacitorUpdater.TAG) Failed to decrypt data")
                throw NSError(domain: "Failed to decrypt data", code: 4, userInfo: nil)
            }

            if decryptedData.isEmpty {
                print("\(CapacitorUpdater.TAG) Decrypted data is empty")
                throw NSError(domain: "Empty decrypted data", code: 7, userInfo: nil)
            }

            do {
                try decryptedData.write(to: filePath, options: .atomic)
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    print("\(CapacitorUpdater.TAG) File was not created after write")
                    throw NSError(domain: "File write failed", code: 8, userInfo: nil)
                }
            } catch {
                print("\(CapacitorUpdater.TAG) Error writing decrypted file: \(error)")
                throw error
            }

        } catch {
            print("\(CapacitorUpdater.TAG) decryptFile fail")
            throw CustomError.cannotDecode
        }
    }
}
