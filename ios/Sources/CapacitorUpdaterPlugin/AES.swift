import Foundation
import CommonCrypto
import CryptoKit
import Darwin

///
/// Constants
///
private enum AESConstants {
    static let aesAlgorithm: CCAlgorithm = CCAlgorithm(kCCAlgorithmAES)
    // CommonCrypto's PKCS7 mode accepts corrupted padding and ciphertext that is not block aligned,
    // so decryption runs without padding and PKCS#7 is checked and removed by `strictPkcs7PaddingLength`.
    static let aesOptions: CCOptions = CCOptions(0)
    static let blockSize = kCCBlockSizeAES128
}

/// Returns the PKCS#7 padding length of the final plaintext block, or nil when the padding is invalid.
func strictPkcs7PaddingLength(lastBlock: [UInt8]) -> Int? {
    guard lastBlock.count == AESConstants.blockSize, let padding = lastBlock.last else {
        return nil
    }
    let length = Int(padding)
    guard length >= 1 && length <= AESConstants.blockSize else {
        return nil
    }
    for byte in lastBlock.suffix(length) where byte != padding {
        return nil
    }
    return length
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
    /// Returns the decrypted data, or nil when the ciphertext is not block aligned or the PKCS#7 padding is invalid.
    ///
    public func decrypt(data: Data) -> Data? {
        guard let plain = decryptBlocks(data) else {
            return nil
        }
        guard let padding = strictPkcs7PaddingLength(lastBlock: Array(plain.suffix(AESConstants.blockSize))) else {
            logger.error("AES decryption failed: invalid padding")
            return nil
        }
        return plain.prefix(plain.count - padding)
    }

    /// AES-CBC decryption of whole blocks, padding left in place. Nil when `data` is empty or not block aligned.
    func decryptBlocks(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % AESConstants.blockSize == 0 else {
            logger.error("AES ciphertext is not block aligned")
            return nil
        }
        var output = [UInt8](repeating: 0, count: data.count)
        var decryptedLength: size_t = 0
        let input = [UInt8](data)
        let keyBytes = [UInt8](aes128Key)
        let ivBytes = [UInt8](initVector)
        let status: CCCryptorStatus = CCCrypt(
            CCOperation(kCCDecrypt),
            AESConstants.aesAlgorithm,
            AESConstants.aesOptions,
            keyBytes,
            keyBytes.count,
            ivBytes,
            input,
            input.count,
            &output,
            output.count,
            &decryptedLength
        )
        guard status == kCCSuccess else {
            logger.error("AES decryption failed with status: \(status)")
            return nil
        }
        return Data(output.prefix(decryptedLength))
    }

    /// Rejects empty ciphertext and ciphertext that is not a whole number of AES blocks.
    private func requireBlockAlignedCiphertext(at source: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard sourceSize > 0, sourceSize % AESConstants.blockSize == 0 else {
            logger.error("AES ciphertext is not block aligned")
            throw NSError(
                domain: "AESDecryptError",
                code: Int(kCCAlignmentError),
                userInfo: [NSLocalizedDescriptionKey: "AES ciphertext is not block aligned"]
            )
        }
    }

    private func makeDecryptor() throws -> CCCryptorRef {
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
        return cryptor
    }

    /// AES-CBC file-to-file. Never holds the whole ciphertext in RAM.
    func decrypt(from source: URL, to destination: URL) throws {
        try requireBlockAlignedCiphertext(at: source)
        let cryptor = try makeDecryptor()
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
        // The last decrypted block carries the padding, so it is held back until the end.
        var heldBlock: [UInt8] = []
        func emit(count: Int) throws {
            guard count > 0 else {
                return
            }
            if !heldBlock.isEmpty {
                try Self.writeAll(fd: outFd, buffer: &heldBlock, count: heldBlock.count)
            }
            let writeCount = count - AESConstants.blockSize
            if writeCount > 0 {
                try Self.writeAll(fd: outFd, buffer: &outBuf, count: writeCount)
            }
            heldBlock = Array(outBuf[writeCount..<count])
        }

        while true {
            let readCount = inBuf.withUnsafeMutableBufferPointer { ptr in
                input.read(ptr.baseAddress!, maxLength: ptr.count)
            }
            if readCount == 0 {
                break
            }
            if readCount < 0 {
                throw input.streamError ?? NSError(domain: "AESDecryptError", code: 2, userInfo: [NSLocalizedDescriptionKey: "AES stream read failed"])
            }
            var moved: size_t = 0
            let status: CCCryptorStatus = inBuf.withUnsafeBufferPointer { inRaw in
                outBuf.withUnsafeMutableBytes { outRaw in
                    CCCryptorUpdate(
                        cryptor,
                        inRaw.baseAddress,
                        readCount,
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
            try emit(count: moved)
        }

        var moved: size_t = 0
        let finalStatus: CCCryptorStatus = outBuf.withUnsafeMutableBytes { outRaw in
            CCCryptorFinal(cryptor, outRaw.baseAddress, outBufSize, &moved)
        }
        guard finalStatus == kCCSuccess else {
            logger.error("AES stream finalize failed")
            throw NSError(domain: "AESDecryptError", code: Int(finalStatus), userInfo: nil)
        }
        try emit(count: moved)
        guard let padding = strictPkcs7PaddingLength(lastBlock: heldBlock) else {
            logger.error("AES decryption failed: invalid padding")
            throw NSError(domain: "AESDecryptError", code: Int(kCCDecodeError), userInfo: [NSLocalizedDescriptionKey: "Invalid AES padding"])
        }
        try Self.writeAll(fd: outFd, buffer: &heldBlock, count: heldBlock.count - padding)
        try output.close()

        let decryptedSize = (try fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if decryptedSize == 0 {
            throw NSError(domain: "Empty decrypted data", code: 7, userInfo: nil)
        }

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
