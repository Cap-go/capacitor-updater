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
/// The RSA keypair. Includes both private and public key.
///
public struct RSAKeyPairV2 {
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
    /// Takes the data and uses the public key to decrypt it.
    /// Returns the decrypted data.
    ///
    public func decrypt(data: Data) -> Data? {
        do {
            guard let decryptedData = RSAPublicKey.decryptWithRSAKey(data, rsaKeyRef: self.publicKey, padding: SecPadding()) else {
                throw CustomError.cannotDecryptSessionKey
            }

            return decryptedData
        } catch {
            print("Error decrypting data: \(error)")
            return nil
        }
    }

    ///
    /// Allows you to load an RSA public key (i.e. one downloaded from the net).
    ///
    public static func load(rsaPublicKey: String) -> RSAPublicKey? {
        var pubKey: String = rsaPublicKey
        pubKey = pubKey.replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
        pubKey = pubKey.replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
        pubKey = pubKey.replacingOccurrences(of: "\\n+", with: "", options: .regularExpression)
        pubKey = pubKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let rsaPublicKeyData: Data = Data(base64Encoded: String(pubKey)) else {
                throw CustomError.cannotDecode
            }

            guard let publicKey: SecKey = .loadPublicFromData(rsaPublicKeyData) else {
                throw CustomError.cannotDecode
            }

            return RSAPublicKey(publicKey: publicKey)
        } catch {
            print("Error load RSA: \(error)")
            return nil
        }
    }

    // code is copied from here: https://github.com/btnguyen2k/swiftutils/blob/88494f4c635b6c6d42ef0fb30a7d666acd38c4fa/SwiftUtils/RSAUtils.swift#L393
    public static func decryptWithRSAKey(_ encryptedData: Data, rsaKeyRef: SecKey, padding: SecPadding) -> Data? {
        let blockSize = SecKeyGetBlockSize(rsaKeyRef)
        let dataSize = encryptedData.count / MemoryLayout<UInt8>.size

        var encryptedDataAsArray = [UInt8](repeating: 0, count: dataSize)
        (encryptedData as NSData).getBytes(&encryptedDataAsArray, length: dataSize)

        var decryptedData = [UInt8](repeating: 0, count: 0)
        var idx = 0
        while idx < encryptedDataAsArray.count {
            var idxEnd = idx + blockSize
            if idxEnd > encryptedDataAsArray.count {
                idxEnd = encryptedDataAsArray.count
            }
            var chunkData = [UInt8](repeating: 0, count: blockSize)
            for i in idx..<idxEnd {
                chunkData[i-idx] = encryptedDataAsArray[i]
            }

            var decryptedDataBuffer = [UInt8](repeating: 0, count: blockSize)
            var decryptedDataLength = blockSize

            let status = SecKeyDecrypt(rsaKeyRef, padding, chunkData, idxEnd-idx, &decryptedDataBuffer, &decryptedDataLength)
            if status != noErr {
                return nil
            }
            let finalData = removePadding(decryptedDataBuffer)
            decryptedData += finalData

            idx += blockSize
        }

        return Data(decryptedData)
    }

    // code is copied from here: https://github.com/btnguyen2k/swiftutils/blob/88494f4c635b6c6d42ef0fb30a7d666acd38c4fa/SwiftUtils/RSAUtils.swift#L429
    private static func removePadding(_ data: [UInt8]) -> [UInt8] {
        var idxFirstZero = -1
        var idxNextZero = data.count
        for i in 0..<data.count {
            if data[i] == 0 {
                if idxFirstZero < 0 {
                    idxFirstZero = i
                } else {
                    idxNextZero = i
                    break
                }
            }
        }
        if idxNextZero-idxFirstZero-1 == 0 {
            idxNextZero = idxFirstZero
            idxFirstZero = -1
        }
        var newData = [UInt8](repeating: 0, count: idxNextZero-idxFirstZero-1)
        for i in idxFirstZero+1..<idxNextZero {
            newData[i-idxFirstZero-1] = data[i]
        }
        return newData
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
