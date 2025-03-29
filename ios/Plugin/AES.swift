import BigInt
import CommonCrypto
import CryptoKit

///
/// Constants
///
private enum AESConstants {
    static let aesAlgorithm: CCAlgorithm = CCAlgorithm(kCCAlgorithmAES)
    static let aesOptions: CCOptions = CCOptions(kCCOptionPKCS7Padding)
}

// We do all this stuff because ios is shit and open source libraries allow to do decryption with public key
// So we have to do it manually, while in nodejs or Java it's ok and done at language level.

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

            let status: CCCryptorStatus = CCCrypt(CCOperation(kCCDecrypt), AESConstants.aesAlgorithm, AESConstants.aesOptions, keyData, keyLength, ivData, encryptedData, encryptedDataLength, decryptedData, decryptedDataLength, &decryptedLength)

            if Int32(status) == Int32(kCCSuccess) {
                result.length = Int(decryptedLength)
                return result as Data
            } else {
                print("\(CapacitorUpdater.TAG) AES decryption failed with status: \(status)")
                return nil
            }
        } else {
            print("\(CapacitorUpdater.TAG) Failed to allocate memory for AES decryption")
            return nil
        }
    }
}
