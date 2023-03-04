/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CommonCrypto

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
/// The AES key. Contains both the initialization vector and secret key.
///
public struct AES128Key {
    /// Initialization vector
    private let iv: Data
    private let aes128Key: Data
    #if DEBUG
    public var __debug_iv: Data { iv }
    public var __debug_aes128Key: Data { aes128Key }
    #endif
    init(iv: Data, aes128Key: Data) {
        self.iv = iv
        self.aes128Key = aes128Key
    }
    ///
    /// Takes the data and uses the private key to decrypt it. Will call `CCCrypt` in CommonCrypto
    /// and provide it `ivData` for the initialization vector. Will use cipher block chaining (CBC) as
    /// the mode of operation.
    ///
    /// Returns the decrypted data.
    ///
    public func decrypt(data: Data) -> Data? {
        let encryptedData: UnsafePointer<UInt8> = (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count)
        let encryptedDataLength: Int = data.count

        if let result: NSMutableData = NSMutableData(length: encryptedDataLength) {
            let keyData: UnsafePointer<UInt8> = (self.aes128Key as NSData).bytes.bindMemory(to: UInt8.self, capacity: self.aes128Key.count)
            let keyLength: size_t = size_t(self.aes128Key.count)
            let ivData: UnsafePointer<UInt8> = (iv as NSData).bytes.bindMemory(to: UInt8.self, capacity: self.iv.count)

            let decryptedData: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>(result.mutableBytes.assumingMemoryBound(to: UInt8.self))
            let decryptedDataLength: size_t = size_t(result.length)

            var decryptedLength: size_t = 0

            let status: CCCryptorStatus = CCCrypt(CCOperation(kCCDecrypt), CryptoCipherConstants.aesAlgorithm, CryptoCipherConstants.aesOptions, keyData, keyLength, ivData, encryptedData, encryptedDataLength, decryptedData, decryptedDataLength, &decryptedLength)

            if UInt32(status) == UInt32(kCCSuccess) {
                result.length = Int(decryptedLength)
                return result as Data
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
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

    public func extractPublicKey() -> RSAPublicKey {
        RSAPublicKey(publicKey: publicKey)
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
}

///
/// The RSA public key.
///
public struct RSAPublicKey {
    private let publicKey: SecKey

    #if DEBUG
    public var __debug_publicKey: SecKey { self.publicKey }
    #endif

    fileprivate init(publicKey: SecKey) {
        self.publicKey = publicKey
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
    ///
    /// Allows you to export the RSA public key to a format (so you can send over the net).
    ///
    public func export() -> Data? {
        return publicKey.exportToData()
    }
    //

    ///
    /// Allows you to load an RSA public key (i.e. one downloaded from the net).
    ///
    public static func load(rsaPublicKeyData: Data) -> RSAPublicKey? {
        if let publicKey: SecKey = .loadPublicFromData(rsaPublicKeyData) {
            return RSAPublicKey(publicKey: publicKey)
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
        let rsaPrivateKeyData: Data = Data(base64Encoded: privKey)!
        if let privateKey: SecKey = .loadPrivateFromData(rsaPrivateKeyData) {
            return RSAPrivateKey(privateKey: privateKey)
        } else {
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
        return SecKeyCreateWithData(data as CFData, keyDict as CFDictionary, nil)
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
