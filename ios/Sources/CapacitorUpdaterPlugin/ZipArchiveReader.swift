/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Compression
import Foundation

enum ZipError: Error, Equatable {
    case unreadableArchive
    case missingEndOfCentralDirectory
    case invalidCentralDirectory
    case invalidLocalFileHeader
    case truncatedEntryData
    case corruptedEntryData
    case encryptedEntry
    case unsupportedCompressionMethod(UInt16)
    case invalidBufferSize
    case entryTooLarge
}

enum ZipEntryType {
    case file
    case directory
    case symlink
}

struct ZipEntry {
    let path: String
    let type: ZipEntryType
    let generalPurposeFlags: UInt16
    let compressionMethod: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64

    var isEncrypted: Bool {
        return generalPurposeFlags & 0x0001 != 0
    }
}

/// Small read-only ZIP reader used to extract downloaded bundles.
///
/// Supports stored (0) and deflate (8) entries, ZIP64 archives, and streams entry contents in
/// `bufferSize` chunks so large files are never fully loaded in memory. Encrypted entries and other
/// compression methods are rejected. Every offset and size read from the archive is bounds-checked, so a
/// corrupt archive throws instead of crashing.
///
/// This reader does not validate entry paths. Callers must resolve `ZipEntry.path` against the destination
/// directory (see `CapgoUpdater.resolvePathInsideDirectory`) before writing anything.
final class ZipArchiveReader {
    static let compressionMethodStored: UInt16 = 0
    static let compressionMethodDeflate: UInt16 = 8
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let localFileHeaderSize = 30

    let entries: [ZipEntry]
    private let fileHandle: FileHandle
    private let fileSize: UInt64

    init(url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.unreadableArchive
        }
        do {
            let size = try handle.seekToEnd()
            self.fileHandle = handle
            self.fileSize = size
            self.entries = try ZipCentralDirectory.readEntries(handle: handle, fileSize: size)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? fileHandle.close()
    }

    /// Streams the uncompressed contents of `entry` to `consumer` in chunks of at most `bufferSize` bytes.
    /// Directory entries produce no data.
    func extract(_ entry: ZipEntry, bufferSize: Int, consumer: (Data) throws -> Void) throws {
        guard bufferSize > 0 else {
            throw ZipError.invalidBufferSize
        }
        if entry.type == .directory {
            return
        }
        if entry.isEncrypted {
            throw ZipError.encryptedEntry
        }

        let header = try ZipBytes.readChunk(handle: fileHandle, fileSize: fileSize, at: entry.localHeaderOffset, count: Self.localFileHeaderSize)
        guard ZipBytes.uint32(header, 0) == Self.localFileHeaderSignature else {
            throw ZipError.invalidLocalFileHeader
        }
        let localFlags = ZipBytes.uint16(header, 6)
        let localMethod = ZipBytes.uint16(header, 8)
        let nameLength = UInt64(ZipBytes.uint16(header, 26))
        let extraLength = UInt64(ZipBytes.uint16(header, 28))
        if localFlags & 0x0001 != 0 {
            throw ZipError.encryptedEntry
        }

        let headerLength = UInt64(Self.localFileHeaderSize) + nameLength + extraLength
        let (dataOffset, overflow) = entry.localHeaderOffset.addingReportingOverflow(headerLength)
        guard !overflow, dataOffset <= fileSize else {
            throw ZipError.invalidLocalFileHeader
        }

        // Like the previous ZIPFoundation-based extraction, the local header decides the compression method
        // while sizes come from the central directory.
        switch localMethod {
        case Self.compressionMethodStored:
            // A stored entry's payload is its content; a size mismatch would read past it into the next records.
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipError.corruptedEntryData
            }
            try readStored(from: dataOffset, size: entry.uncompressedSize, bufferSize: bufferSize, consumer: consumer)
        case Self.compressionMethodDeflate:
            if entry.compressedSize == 0 && entry.uncompressedSize == 0 {
                // Some writers store empty files as deflate with no payload at all.
                return
            }
            try readDeflated(
                from: dataOffset,
                compressedSize: entry.compressedSize,
                expectedSize: entry.uncompressedSize,
                bufferSize: bufferSize,
                consumer: consumer
            )
        default:
            throw ZipError.unsupportedCompressionMethod(localMethod)
        }
    }

    /// Reads the full contents of a small entry (e.g. a symlink target), refusing entries larger than `maxBytes`.
    func readSmallEntry(_ entry: ZipEntry, maxBytes: Int, bufferSize: Int) throws -> Data {
        var result = Data()
        try extract(entry, bufferSize: bufferSize) { chunk in
            guard result.count + chunk.count <= maxBytes else {
                throw ZipError.entryTooLarge
            }
            result.append(chunk)
        }
        return result
    }

    private func readStored(from offset: UInt64, size: UInt64, bufferSize: Int, consumer: (Data) throws -> Void) throws {
        guard size <= fileSize, offset <= fileSize - size else {
            throw ZipError.truncatedEntryData
        }
        try fileHandle.seek(toOffset: offset)
        var remaining = size
        while remaining > 0 {
            let chunkSize = Int(min(UInt64(bufferSize), remaining))
            try autoreleasepool {
                guard let chunk = try fileHandle.read(upToCount: chunkSize), chunk.count == chunkSize else {
                    throw ZipError.truncatedEntryData
                }
                try consumer(chunk)
            }
            remaining -= UInt64(chunkSize)
        }
    }

    /// Inflates an entry, rejecting output that differs from the central directory's uncompressed size.
    /// This also bounds decompression bombs to the declared size.
    private func readDeflated(
        from offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64,
        bufferSize: Int,
        consumer: (Data) throws -> Void
    ) throws {
        guard compressedSize <= fileSize, offset <= fileSize - compressedSize else {
            throw ZipError.truncatedEntryData
        }
        try fileHandle.seek(toOffset: offset)

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        // COMPRESSION_ZLIB decodes raw DEFLATE (RFC 1951), which is what ZIP method 8 stores.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corruptedEntryData
        }
        defer { compression_stream_destroy(stream) }

        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { sourceBuffer.deallocate() }
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        var remaining = compressedSize
        stream.pointee.src_ptr = UnsafePointer(sourceBuffer)
        stream.pointee.src_size = 0

        var producedTotal: UInt64 = 0
        var finished = false
        while !finished {
            try autoreleasepool {
                if stream.pointee.src_size == 0 && remaining > 0 {
                    let chunkSize = Int(min(UInt64(bufferSize), remaining))
                    guard let chunk = try fileHandle.read(upToCount: chunkSize), chunk.count == chunkSize else {
                        throw ZipError.truncatedEntryData
                    }
                    chunk.copyBytes(to: sourceBuffer, count: chunkSize)
                    stream.pointee.src_ptr = UnsafePointer(sourceBuffer)
                    stream.pointee.src_size = chunkSize
                    remaining -= UInt64(chunkSize)
                }

                stream.pointee.dst_ptr = destinationBuffer
                stream.pointee.dst_size = bufferSize
                let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(stream, flags)
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    producedTotal += UInt64(produced)
                    guard producedTotal <= expectedSize else {
                        throw ZipError.corruptedEntryData
                    }
                    try consumer(Data(bytes: destinationBuffer, count: produced))
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    guard producedTotal == expectedSize else {
                        throw ZipError.corruptedEntryData
                    }
                    finished = true
                case COMPRESSION_STATUS_OK:
                    // All input consumed and no output produced: the deflate stream is truncated.
                    if remaining == 0 && stream.pointee.src_size == 0 && produced == 0 {
                        throw ZipError.truncatedEntryData
                    }
                default:
                    throw ZipError.corruptedEntryData
                }
            }
        }
    }
}
