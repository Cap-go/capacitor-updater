import BigInt
import Foundation
import CommonCrypto
import CryptoKit

///
/// Constants
///
private enum RSAConstants {
    static let rsaKeySizeInBits: NSNumber = 2048
    static let rsaAlgorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256
}

// We do all this stuff because ios is shit and open source libraries allow to do decryption with public key
// So we have to do it manually, while in nodejs or Java it's ok and done at language level.

///
/// The RSA public key.
///
public struct RSAPublicKey {
    private let manualKey: ManualRSAPublicKey

    fileprivate init(manualKey: ManualRSAPublicKey) {
        self.manualKey = manualKey
    }

    ///
    /// Takes the data and uses the public key to decrypt it.
    /// Returns the decrypted data.
    ///
    public func decrypt(data: Data) -> Data? {
        return manualKey.decrypt(data)
    }

    ///
    /// Allows you to load an RSA public key (i.e. one downloaded from the net).
    ///
    public static func load(rsaPublicKey: String) -> RSAPublicKey? {
        // Clean up the key string
        var pubKey: String = rsaPublicKey
        pubKey = pubKey.replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
        pubKey = pubKey.replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
        pubKey = pubKey.replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
        pubKey = pubKey.replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
        pubKey = pubKey.replacingOccurrences(of: "\\n+", with: "", options: .regularExpression)
        pubKey = pubKey.replacingOccurrences(of: "\n", with: "")
        pubKey = pubKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            guard let rsaPublicKeyData: Data = Data(base64Encoded: String(pubKey)) else {
                throw CustomError.cannotDecode
            }

            // Try parsing as PKCS#1
            if let manualKey = ManualRSAPublicKey.fromPKCS1(rsaPublicKeyData) {
                return RSAPublicKey(manualKey: manualKey)
            }

            // Most common public exponent is 65537 (0x010001)
            let commonExponent = Data([0x01, 0x00, 0x01]) // 65537 in big-endian

            // Assume the entire key data is the modulus
            let lastResortKey = ManualRSAPublicKey(modulus: rsaPublicKeyData, exponent: commonExponent)
            return RSAPublicKey(manualKey: lastResortKey)
        } catch {
            return nil
        }
    }
}

// Manual RSA Public Key Implementation using the BigInt library
struct ManualRSAPublicKey {
    let modulus: BigInt
    let exponent: BigInt

    init(modulus: Data, exponent: Data) {
        // Create positive BigInts from Data
        let modulusBytes = [UInt8](modulus)
        var modulusValue = BigUInt(0)
        for byte in modulusBytes {
            modulusValue = (modulusValue << 8) | BigUInt(byte)
        }
        self.modulus = BigInt(modulusValue)
        let exponentBytes = [UInt8](exponent)
        var exponentValue = BigUInt(0)
        for byte in exponentBytes {
            exponentValue = (exponentValue << 8) | BigUInt(byte)
        }
        self.exponent = BigInt(exponentValue)
    }

    // Parse PKCS#1 format public key
    static func fromPKCS1(_ publicKeyData: Data) -> ManualRSAPublicKey? {
        // Parse ASN.1 DER encoded RSA public key
        // Format: RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }

        guard publicKeyData.count > 0 else {
            return nil
        }

        let bytes = [UInt8](publicKeyData)

        // Check for sequence tag (0x30)
        guard bytes[0] == 0x30 else {
            // Try direct modulus/exponent approach as fallback
            if publicKeyData.count >= 3 {
                // Assume this is a raw RSA public key with modulus + exponent
                // Most common: modulus is 256 bytes (2048 bits), exponent is 3 bytes (0x010001 = 65537)
                let modulusSize = publicKeyData.count - 3
                if modulusSize > 0 {
                    let modulusData = publicKeyData.prefix(modulusSize)
                    let exponentData = publicKeyData.suffix(3)
                    return ManualRSAPublicKey(modulus: modulusData, exponent: exponentData)
                }
            }

            return nil
        }

        var index = 1

        // Skip length
        if bytes[index] & 0x80 != 0 {
            let lenBytes = Int(bytes[index] & 0x7F)
            if (index + 1 + lenBytes) >= bytes.count {
                return nil
            }
            index += 1 + lenBytes
        } else {
            index += 1
        }

        // Check for INTEGER tag for modulus (0x02)
        if index >= bytes.count {
            return nil
        }

        guard bytes[index] == 0x02 else {
            return nil
        }
        index += 1

        // Get modulus length
        if index >= bytes.count {
            return nil
        }

        var modulusLength = 0
        if bytes[index] & 0x80 != 0 {
            let lenBytes = Int(bytes[index] & 0x7F)
            if (index + 1 + lenBytes) >= bytes.count {
                return nil
            }
            index += 1
            for i in 0..<lenBytes {
                modulusLength = (modulusLength << 8) | Int(bytes[index + i])
            }
            index += lenBytes
        } else {
            modulusLength = Int(bytes[index])
            index += 1
        }

        // Skip any leading zero in modulus (for unsigned integer)
        if index < bytes.count && bytes[index] == 0x00 {
            index += 1
            modulusLength -= 1
        }

        // Extract modulus
        if (index + modulusLength) > bytes.count {
            return nil
        }

        let modulusData = Data(bytes[index..<(index + modulusLength)])
        index += modulusLength

        // Check for INTEGER tag for exponent
        if index >= bytes.count {
            return nil
        }

        guard bytes[index] == 0x02 else {
            return nil
        }
        index += 1

        // Get exponent length
        if index >= bytes.count {
            return nil
        }

        var exponentLength = 0
        if bytes[index] & 0x80 != 0 {
            let lenBytes = Int(bytes[index] & 0x7F)
            if (index + 1 + lenBytes) >= bytes.count {
                return nil
            }
            index += 1
            for i in 0..<lenBytes {
                exponentLength = (exponentLength << 8) | Int(bytes[index + i])
            }
            index += lenBytes
        } else {
            exponentLength = Int(bytes[index])
            index += 1
        }

        // Extract exponent
        if (index + exponentLength) > bytes.count {
            return nil
        }

        let exponentData = Data(bytes[index..<(index + exponentLength)])
        return ManualRSAPublicKey(modulus: modulusData, exponent: exponentData)
    }

    // Decrypt data using raw RSA operation (c^d mod n)
    func decrypt(_ encryptedData: Data) -> Data? {
        // Create positive BigInt from encrypted data
        let encryptedBytes = [UInt8](encryptedData)
        var encryptedValue = BigUInt(0)
        for byte in encryptedBytes {
            encryptedValue = (encryptedValue << 8) | BigUInt(byte)
        }
        let encrypted = BigInt(encryptedValue)

        // In Node.js:
        // privateEncrypt uses the private key (d) to encrypt
        // publicDecrypt uses the public key (e) to decrypt
        // The operation we want is: ciphertext^e mod n

        // RSA operation: c^e mod n
        let decrypted = encrypted.manualPower(exponent, modulus: modulus)

        // Convert to bytes with proper padding
        guard let bigUIntValue = decrypted.magnitude as? BigUInt else {
            return nil
        }

        // Convert BigUInt to bytes with padding
        var resultBytes = [UInt8]()
        var tempValue = bigUIntValue
        while tempValue > 0 {
            let byte = UInt8(tempValue & 0xFF)
            resultBytes.insert(byte, at: 0)  // Prepend to get big-endian
            tempValue >>= 8
        }

        // Ensure we have at least 256 bytes (2048 bits) with leading zeros
        let paddedBytes = [UInt8](repeating: 0, count: max(0, 256 - resultBytes.count)) + resultBytes

        // For PKCS1 padding from Node.js privateEncrypt, the format is:
        // 0x00 || 0x01 || PS || 0x00 || actual data
        // where PS is a string of 0xFF bytes

        // Check for privateEncrypt padding format (0x00 || 0x01 || PS || 0x00)
        var startIndex = 0
        if paddedBytes.count > 2 && paddedBytes[0] == 0x00 && paddedBytes[1] == 0x01 {
            for i in 2..<paddedBytes.count {
                if paddedBytes[i] == 0x00 {
                    startIndex = i + 1
                    break
                }
            }
        }
        if startIndex < paddedBytes.count {
            let result = Data(paddedBytes[startIndex...])
            return result
        } else {
            return Data(paddedBytes)
        }
    }
}
