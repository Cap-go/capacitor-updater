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

            guard rsaPublicKeyData.first != 0x30 else {
                return nil
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

    private struct DERReader {
        let bytes: [UInt8]
        var index: Int

        mutating func readTag(_ tag: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == tag else {
                return false
            }
            index += 1
            return true
        }

        mutating func readLength() -> Int? {
            guard index < bytes.count else {
                return nil
            }

            if bytes[index] & 0x80 == 0 {
                let length = Int(bytes[index])
                index += 1
                return length
            }

            let lengthByteCount = Int(bytes[index] & 0x7F)
            guard index + lengthByteCount < bytes.count else {
                return nil
            }

            index += 1
            var length = 0
            for offset in 0..<lengthByteCount {
                length = (length << 8) | Int(bytes[index + offset])
            }
            index += lengthByteCount
            return length
        }

        mutating func readIntegerData() -> Data? {
            guard readTag(0x02), var length = readLength(), index + length <= bytes.count else {
                return nil
            }

            if length > 0 && bytes[index] == 0x00 {
                index += 1
                length -= 1
            }

            guard index + length <= bytes.count else {
                return nil
            }

            let value = Data(bytes[index..<(index + length)])
            index += length
            return value
        }
    }

    static func rawKeyFallback(_ publicKeyData: Data) -> ManualRSAPublicKey? {
        guard publicKeyData.count >= 3 else {
            return nil
        }

        let modulusSize = publicKeyData.count - 3
        guard modulusSize > 0 else {
            return nil
        }

        let modulusData = publicKeyData.prefix(modulusSize)
        let exponentData = publicKeyData.suffix(3)
        return ManualRSAPublicKey(modulus: modulusData, exponent: exponentData)
    }

    private static func parsePKCS1Sequence(_ bytes: [UInt8]) -> ManualRSAPublicKey? {
        var reader = DERReader(bytes: bytes, index: 0)
        guard reader.readTag(0x30),
              let sequenceLength = reader.readLength(),
              reader.index + sequenceLength <= bytes.count,
              let modulusData = reader.readIntegerData(),
              let exponentData = reader.readIntegerData() else {
            return nil
        }
        return ManualRSAPublicKey(modulus: modulusData, exponent: exponentData)
    }

    private static func parseSubjectPublicKeyInfo(_ bytes: [UInt8]) -> ManualRSAPublicKey? {
        var reader = DERReader(bytes: bytes, index: 0)
        guard reader.readTag(0x30),
              let outerLength = reader.readLength(),
              reader.index + outerLength <= bytes.count else {
            return nil
        }
        let outerEnd = reader.index + outerLength

        guard reader.readTag(0x30),
              let algorithmLength = reader.readLength(),
              reader.index + algorithmLength <= outerEnd else {
            return nil
        }
        let algorithmEnd = reader.index + algorithmLength

        guard reader.readTag(0x06),
              let oidLength = reader.readLength(),
              reader.index + oidLength <= algorithmEnd else {
            return nil
        }
        let rsaEncryptionOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        let oid = Array(bytes[reader.index..<(reader.index + oidLength)])
        guard oid == rsaEncryptionOID else {
            return nil
        }

        reader.index = algorithmEnd
        guard reader.readTag(0x03),
              let bitStringLength = reader.readLength(),
              bitStringLength > 1,
              reader.index + bitStringLength <= outerEnd,
              bytes[reader.index] == 0x00 else {
            return nil
        }

        let payloadStart = reader.index + 1
        let payloadEnd = reader.index + bitStringLength
        return parsePKCS1Sequence(Array(bytes[payloadStart..<payloadEnd]))
    }

    // Parse PKCS#1 or SubjectPublicKeyInfo format public key
    static func fromPKCS1(_ publicKeyData: Data) -> ManualRSAPublicKey? {
        guard !publicKeyData.isEmpty else {
            return nil
        }

        let bytes = [UInt8](publicKeyData)
        guard bytes[0] == 0x30 else {
            return rawKeyFallback(publicKeyData)
        }

        return parsePKCS1Sequence(bytes) ?? parseSubjectPublicKeyInfo(bytes)
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
            for byteIndex in 2..<paddedBytes.count where paddedBytes[byteIndex] == 0x00 {
                startIndex = byteIndex + 1
                break
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
