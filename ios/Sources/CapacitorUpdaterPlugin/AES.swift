import Foundation
import CommonCrypto
import CryptoKit
import Darwin

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
    private let initVector: Data
    private let logger: Logger
    private let aes128Key: Data
    #if DEBUG
    // swiftlint:disable:next identifier_name
    public var __debug_iv: Data { initVector }
    // swiftlint:disable:next identifier_name
    public var __debug_aes128Key: Data { aes128Key }
    #endif
    // swiftlint:disable:next identifier_name
    init(iv: Data, aes128Key: Data, logger: Logger) {
        self.initVector = iv
        self.aes128Key = aes128Key
        self.logger = logger
    }
    ///
    /// Takes the data and uses the private key to decrypt it. Will call `CCCrypt` in CommonCrypto
    /// and provide it `ivData` for the initialization vector. Will use cipher block chaining (CBC) as
    /// the mode of operation.
    ///
    /// Returns the decrypted data.
    ///
    public func decrypt(data: Data) -> Data? {
        let encryptedData: UnsafePointer<UInt8> = (data as NSData).bytes.bindMemory(
            to: UInt8.self, capacity: data.count)
        let encryptedDataLength: Int = data.count

        if let result: NSMutableData = NSMutableData(length: encryptedDataLength) {
            let keyData: UnsafePointer<UInt8> = (self.aes128Key as NSData).bytes.bindMemory(
                to: UInt8.self, capacity: self.aes128Key.count)
            let keyLength: size_t = size_t(self.aes128Key.count)
            let ivData: UnsafePointer<UInt8> = (initVector as NSData).bytes.bindMemory(
                to: UInt8.self, capacity: self.initVector.count)

            let decryptedData: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>(
                result.mutableBytes.assumingMemoryBound(to: UInt8.self))
            let decryptedDataLength: size_t = size_t(result.length)

            var decryptedLength: size_t = 0

            let status: CCCryptorStatus = CCCrypt(
                CCOperation(kCCDecrypt),
                AESConstants.aesAlgorithm,
                AESConstants.aesOptions,
                keyData,
                keyLength,
                ivData,
                encryptedData,
                encryptedDataLength,
                decryptedData,
                decryptedDataLength,
                &decryptedLength)

            if Int32(status) == Int32(kCCSuccess) {
                result.length = Int(decryptedLength)
                return result as Data
            } else {
                logger.error("AES decryption failed with status: \(status)")
                return nil
            }
        } else {
            logger.error("Failed to allocate memory for AES decryption")
            return nil
        }
    }

    /// AES-CBC file-to-file. Never holds the whole ciphertext in RAM.
    func decrypt(from source: URL, to destination: URL) throws {
        var cryptor: CCCryptorRef?
        let createStatus: CCCryptorStatus = aes128Key.withUnsafeBytes { keyBytes in
            initVector.withUnsafeBytes { ivBytes in
                guard let keyPtr = keyBytes.baseAddress, let ivPtr = ivBytes.baseAddress else {
                    return CCCryptorStatus(kCCParamError)
                }
                return CCCryptorCreate(
                    CCOperation(kCCDecrypt),
                    AESConstants.aesAlgorithm,
                    AESConstants.aesOptions,
                    keyPtr,
                    keyBytes.count,
                    ivPtr,
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            logger.error("Failed to create AES cryptor")
            throw NSError(domain: "AESDecryptError", code: Int(createStatus), userInfo: nil)
        }
        defer {
            CCCryptorRelease(cryptor)
        }

        guard let input = InputStream(url: source) else {
            throw NSError(domain: "AESDecryptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open AES source"])
        }
        input.open()
        defer {
            input.close()
        }

        let tempURL = destination.deletingLastPathComponent().appendingPathComponent("capgo-aes-\(UUID().uuidString).tmp")
        let fileManager = FileManager.default
        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: tempURL)
        defer {
            try? output.close()
            try? fileManager.removeItem(at: tempURL)
        }

        let bufferSize = CryptoCipher.ioBufferBytes()
        let outBufSize = bufferSize + kCCBlockSizeAES128
        var inBuf = [UInt8](repeating: 0, count: bufferSize)
        var outBuf = [UInt8](repeating: 0, count: outBufSize)
        let outFd = output.fileDescriptor

        while true {
            let n = inBuf.withUnsafeMutableBufferPointer { ptr in
                input.read(ptr.baseAddress!, maxLength: ptr.count)
            }
            if n == 0 {
                break
            }
            if n < 0 {
                throw input.streamError ?? NSError(domain: "AESDecryptError", code: 2, userInfo: [NSLocalizedDescriptionKey: "AES stream read failed"])
            }
            var moved: size_t = 0
            let status: CCCryptorStatus = inBuf.withUnsafeBufferPointer { inRaw in
                outBuf.withUnsafeMutableBytes { outRaw in
                    CCCryptorUpdate(
                        cryptor,
                        inRaw.baseAddress,
                        n,
                        outRaw.baseAddress,
                        outBufSize,
                        &moved
                    )
                }
            }
            guard status == kCCSuccess else {
                logger.error("AES stream update failed")
                throw NSError(domain: "AESDecryptError", code: Int(status), userInfo: nil)
            }
            if moved > 0 {
                try Self.writeAll(fd: outFd, buffer: &outBuf, count: moved)
            }
        }

        var moved: size_t = 0
        let finalStatus: CCCryptorStatus = outBuf.withUnsafeMutableBytes { outRaw in
            CCCryptorFinal(cryptor, outRaw.baseAddress, outBufSize, &moved)
        }
        guard finalStatus == kCCSuccess else {
            logger.error("AES stream finalize failed")
            throw NSError(domain: "AESDecryptError", code: Int(finalStatus), userInfo: nil)
        }
        if moved > 0 {
            try Self.writeAll(fd: outFd, buffer: &outBuf, count: moved)
        }
        try output.close()

        do {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                throw error
            }
            try fileManager.moveItem(at: tempURL, to: destination)
        }
    }

    private static func writeAll(fd: Int32, buffer: inout [UInt8], count: Int) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBufferPointer { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            if written <= 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "AES stream write failed"])
            }
            offset += written
        }
    }
}
