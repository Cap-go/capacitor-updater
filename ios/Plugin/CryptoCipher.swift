/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CommonCrypto
import zlib

///
/// Constants
///
private enum CryptoCipherConstants {
    static let rsaKeySizeInBits: NSNumber = 2048
    static let aesAlgorithm: CCAlgorithm = CCAlgorithm(kCCAlgorithmAES)
    static let aesOptions: CCOptions = CCOptions(kCCOptionPKCS7Padding)
    static let rsaAlgorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256
}
///
/// The RSA keypair. Includes both private and public key.
///
public struct RSAKeyPair {
    private let privateKey: SecKey
    private let publicKey: SecKey

    #if DEBUG
    public var __debug_privateKey: SecKey { self.privateKey }
    public var __debug_publicKey: SecKey { self.publicKey }
    #endif

    fileprivate init(privateKey: SecKey, publicKey: SecKey) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    ///
    /// Takes the data and uses the private key to decrypt it.
    /// Returns the decrypted data.
    ///
    public func decrypt(data: Data) -> Data? {
        var error: Unmanaged<CFError>?
        if let decryptedData: CFData = SecKeyCreateDecryptedData(self.privateKey, CryptoCipherConstants.rsaAlgorithm, data as CFData, &error) {
            if error != nil {
                return nil
            } else {
                return decryptedData as Data
            }
        } else {
            return nil
        }
    }

    ///
    /// Takes the data and uses the public key to encrypt it.
    /// Returns the encrypted data.
    ///
    public func encrypt(data: Data) -> Data? {
        var error: Unmanaged<CFError>?
        if let encryptedData: CFData = SecKeyCreateEncryptedData(self.publicKey, CryptoCipherConstants.rsaAlgorithm, data as CFData, &error) {
            if error != nil {
                return nil
            } else {
                return encryptedData as Data
            }
        } else {
            return nil
        }
    }

}
///
/// The RSA public key.
///
public struct RSAPrivateKey {
    private let privateKey: SecKey

    #if DEBUG
    public var __debug_privateKey: SecKey { self.privateKey }
    #endif

    fileprivate init(privateKey: SecKey) {
        self.privateKey = privateKey
    }
    ///
    /// Takes the data and uses the private key to decrypt it.
    /// Returns the decrypted data.
    ///
    public func decrypt(data: Data) -> Data? {
        var error: Unmanaged<CFError>?
        if let decryptedData: CFData = SecKeyCreateDecryptedData(self.privateKey, CryptoCipherConstants.rsaAlgorithm, data as CFData, &error) {
            if error != nil {
                return nil
            } else {
                return decryptedData as Data
            }
        } else {
            return nil
        }
    }

    ///
    /// Allows you to export the RSA public key to a format (so you can send over the net).
    ///
    public func export() -> Data? {
        return privateKey.exportToData()
    }

    ///
    /// Allows you to load an RSA public key (i.e. one downloaded from the net).
    ///
    public static func load(rsaPrivateKey: String) -> RSAPrivateKey? {
        var privKey: String = rsaPrivateKey
        privKey = privKey.replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
        privKey = privKey.replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
        privKey = privKey.replacingOccurrences(of: "\\n+", with: "", options: .regularExpression)
        privKey = privKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let rsaPrivateKeyData: Data  = Data(base64Encoded: privKey) else {
                throw CustomError.cannotDecode
            }
            guard let privateKey: SecKey = .loadPrivateFromData(rsaPrivateKeyData) else {
                throw CustomError.cannotDecode
            }
            return RSAPrivateKey(privateKey: privateKey)
        } catch {
            print("Error load RSA: \(error)")
            return nil
        }
    }
}

fileprivate extension SecKey {
    func exportToData() -> Data? {
        var error: Unmanaged<CFError>?
        if let cfData: CFData = SecKeyCopyExternalRepresentation(self, &error) {
            if error != nil {
                return nil
            } else {
                return cfData as Data
            }
        } else {
            return nil
        }
    }
    static func loadPublicFromData(_ data: Data) -> SecKey? {
        let keyDict: [NSObject: NSObject] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: CryptoCipherConstants.rsaKeySizeInBits
        ]
        return SecKeyCreateWithData(data as NSData, keyDict as CFDictionary, nil)
    }
    static func loadPrivateFromData(_ data: Data) -> SecKey? {
        let keyDict: [NSObject: NSObject] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: CryptoCipherConstants.rsaKeySizeInBits
        ]
        return SecKeyCreateWithData(data as CFData, keyDict as CFDictionary, nil)
    }
}

public struct CryptoCipher {
    public static func calcChecksum(filePath: URL) -> String {
        let bufferSize = 1024 * 1024 * 5 // 5 MB
        var checksum = uLong(0)

        do {
            let fileHandle = try FileHandle(forReadingFrom: filePath)
            defer {
                fileHandle.closeFile()
            }

            while autoreleasepool(invoking: {
                let fileData = fileHandle.readData(ofLength: bufferSize)
                if fileData.count > 0 {
                    checksum = fileData.withUnsafeBytes {
                        crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(fileData.count))
                    }
                    return true // Continue
                } else {
                    return false // End of file
                }
            }) {}

            return String(format: "%08X", checksum).lowercased()
        } catch {
            print("\(CapacitorUpdater.TAG) Cannot get checksum: \(filePath.path)", error)
            return ""
        }
    }
    public static func decryptFile(filePath: URL, privateKey: String, sessionKey: String, version: String) throws {
        if privateKey.isEmpty {
            print("\(CapacitorUpdater.TAG) Cannot found privateKey")
            return
        } else if sessionKey.isEmpty  || sessionKey.components(separatedBy: ":").count != 2 {
            print("\(CapacitorUpdater.TAG) Cannot found sessionKey")
            return
        }
        do {
            guard let rsaPrivateKey: RSAPrivateKey = .load(rsaPrivateKey: privateKey) else {
                print("cannot decode privateKey", privateKey)
                throw CustomError.cannotDecode
            }

            let sessionKeyArray: [String] = sessionKey.components(separatedBy: ":")
            guard let ivData: Data = Data(base64Encoded: sessionKeyArray[0]) else {
                print("cannot decode sessionKey", sessionKey)
                throw CustomError.cannotDecode
            }

            guard let sessionKeyDataEncrypted = Data(base64Encoded: sessionKeyArray[1]) else {
                throw NSError(domain: "Invalid session key data", code: 1, userInfo: nil)
            }

            guard let sessionKeyDataDecrypted = rsaPrivateKey.decrypt(data: sessionKeyDataEncrypted) else {
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            let aesPrivateKey = AES128Key(iv: ivData, aes128Key: sessionKeyDataDecrypted)

            guard let encryptedData = try? Data(contentsOf: filePath) else {
                throw NSError(domain: "Failed to read encrypted data", code: 3, userInfo: nil)
            }

            guard let decryptedData = aesPrivateKey.decrypt(data: encryptedData) else {
                throw NSError(domain: "Failed to decrypt data", code: 4, userInfo: nil)
            }

            try decryptedData.write(to: filePath)

        } catch {
            print("\(CapacitorUpdater.TAG) Cannot decode: \(filePath.path)", error)
            throw CustomError.cannotDecode
        }
    }
}
