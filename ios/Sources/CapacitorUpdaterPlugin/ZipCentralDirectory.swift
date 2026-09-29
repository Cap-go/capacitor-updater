/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// Parses the ZIP end of central directory (including ZIP64) and the central directory entries.
/// Every offset and length is bounds-checked; malformed input throws `ZipError`.
enum ZipCentralDirectory {
    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let zip64EocdSignature: UInt32 = 0x0606_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let entrySignature: UInt32 = 0x0201_4b50
    private static let eocdSize = 22
    private static let zip64LocatorSize = 20
    private static let zip64EocdMinimumSize = 56
    private static let entryMinimumSize = 46
    private static let maxCommentLength = 0xFFFF
    private static let zip64ExtraFieldId: UInt16 = 0x0001

    private struct EntrySizes {
        var uncompressed: UInt64
        var compressed: UInt64
        var localHeaderOffset: UInt64
    }

    private struct Location {
        var totalEntries: UInt64
        var size: UInt64
        var offset: UInt64
        /// The central directory must end before this offset (the EOCD or ZIP64 EOCD record).
        var end: UInt64
    }

    static func readEntries(handle: FileHandle, fileSize: UInt64) throws -> [ZipEntry] {
        let location = try locateCentralDirectory(handle: handle, fileSize: fileSize)
        guard location.offset <= location.end, location.size <= location.end - location.offset else {
            throw ZipError.invalidCentralDirectory
        }
        // Every central directory entry takes at least 46 bytes, which bounds the entry count.
        guard location.totalEntries <= location.size / UInt64(entryMinimumSize), location.size <= UInt64(Int.max) else {
            throw ZipError.invalidCentralDirectory
        }

        let data = try ZipBytes.readChunk(handle: handle, fileSize: fileSize, at: location.offset, count: Int(location.size))
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(location.totalEntries))
        var cursor = 0
        for _ in 0..<location.totalEntries {
            let (entry, next) = try parseEntry(data, at: cursor)
            entries.append(entry)
            cursor = next
        }
        return entries
    }

    private static func locateCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> Location {
        guard fileSize >= UInt64(eocdSize) else {
            throw ZipError.missingEndOfCentralDirectory
        }

        // The EOCD record is at the end of the file, followed by an optional comment of up to 65535 bytes.
        let tailLength = min(fileSize, UInt64(eocdSize + maxCommentLength))
        let tailOffset = fileSize - tailLength
        let tail = try ZipBytes.readChunk(handle: handle, fileSize: fileSize, at: tailOffset, count: Int(tailLength))

        var eocdIndex: Int?
        var index = tail.count - eocdSize
        while index >= 0 {
            if ZipBytes.uint32(tail, index) == eocdSignature,
               index + eocdSize + Int(ZipBytes.uint16(tail, index + 20)) <= tail.count {
                eocdIndex = index
                break
            }
            index -= 1
        }
        guard let eocdIndex else {
            throw ZipError.missingEndOfCentralDirectory
        }

        let eocdOffset = tailOffset + UInt64(eocdIndex)
        let location = Location(
            totalEntries: UInt64(ZipBytes.uint16(tail, eocdIndex + 10)),
            size: UInt64(ZipBytes.uint32(tail, eocdIndex + 12)),
            offset: UInt64(ZipBytes.uint32(tail, eocdIndex + 16)),
            end: eocdOffset
        )
        let needsZip64 = location.totalEntries == 0xFFFF || location.size == 0xFFFF_FFFF || location.offset == 0xFFFF_FFFF
        if let zip64Location = try readZip64Location(handle: handle, fileSize: fileSize, eocdOffset: eocdOffset) {
            return zip64Location
        }
        if needsZip64 {
            throw ZipError.invalidCentralDirectory
        }
        return location
    }

    private static func readZip64Location(handle: FileHandle, fileSize: UInt64, eocdOffset: UInt64) throws -> Location? {
        guard eocdOffset >= UInt64(zip64LocatorSize) else {
            return nil
        }
        let locatorOffset = eocdOffset - UInt64(zip64LocatorSize)
        let locator = try ZipBytes.readChunk(handle: handle, fileSize: fileSize, at: locatorOffset, count: zip64LocatorSize)
        guard ZipBytes.uint32(locator, 0) == zip64LocatorSignature else {
            return nil
        }
        let recordOffset = ZipBytes.uint64(locator, 8)
        guard recordOffset <= locatorOffset, locatorOffset - recordOffset >= UInt64(zip64EocdMinimumSize) else {
            throw ZipError.invalidCentralDirectory
        }
        let record = try ZipBytes.readChunk(handle: handle, fileSize: fileSize, at: recordOffset, count: zip64EocdMinimumSize)
        guard ZipBytes.uint32(record, 0) == zip64EocdSignature else {
            throw ZipError.invalidCentralDirectory
        }
        return Location(
            totalEntries: ZipBytes.uint64(record, 32),
            size: ZipBytes.uint64(record, 40),
            offset: ZipBytes.uint64(record, 48),
            end: recordOffset
        )
    }

    private static func parseEntry(_ data: Data, at offset: Int) throws -> (ZipEntry, Int) {
        guard offset <= data.count - entryMinimumSize, ZipBytes.uint32(data, offset) == entrySignature else {
            throw ZipError.invalidCentralDirectory
        }
        let versionMadeBy = ZipBytes.uint16(data, offset + 4)
        let flags = ZipBytes.uint16(data, offset + 8)
        let nameLength = Int(ZipBytes.uint16(data, offset + 28))
        let extraLength = Int(ZipBytes.uint16(data, offset + 30))
        let commentLength = Int(ZipBytes.uint16(data, offset + 32))
        let externalAttributes = ZipBytes.uint32(data, offset + 38)

        let nameStart = offset + entryMinimumSize
        let extraStart = nameStart + nameLength
        let next = extraStart + extraLength + commentLength
        guard next <= data.count else {
            throw ZipError.invalidCentralDirectory
        }

        var sizes = EntrySizes(
            uncompressed: UInt64(ZipBytes.uint32(data, offset + 24)),
            compressed: UInt64(ZipBytes.uint32(data, offset + 20)),
            localHeaderOffset: UInt64(ZipBytes.uint32(data, offset + 42))
        )
        if sizes.uncompressed == 0xFFFF_FFFF || sizes.compressed == 0xFFFF_FFFF || sizes.localHeaderOffset == 0xFFFF_FFFF {
            sizes = try applyZip64Extra(data, extraRange: extraStart..<(extraStart + extraLength), sizes: sizes)
        }

        // Same path decoding as ZIPFoundation: UTF-8 when general purpose bit 11 is set, CP437 otherwise.
        let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + extraStart))
        let encoding: String.Encoding = flags & (1 << 11) != 0 ? .utf8 : codePage437
        let path = String(data: nameData, encoding: encoding) ?? ""

        let entry = ZipEntry(
            path: path,
            type: entryType(path: path, versionMadeBy: versionMadeBy, externalAttributes: externalAttributes),
            generalPurposeFlags: flags,
            compressionMethod: ZipBytes.uint16(data, offset + 10),
            compressedSize: sizes.compressed,
            uncompressedSize: sizes.uncompressed,
            localHeaderOffset: sizes.localHeaderOffset
        )
        return (entry, next)
    }

    /// ZIP64 extended information: values are present only for fields saturated in the fixed record, in this order.
    private static func applyZip64Extra(
        _ data: Data,
        extraRange: Range<Int>,
        sizes: EntrySizes
    ) throws -> EntrySizes {
        var cursor = extraRange.lowerBound
        while cursor + 4 <= extraRange.upperBound {
            let headerId = ZipBytes.uint16(data, cursor)
            let fieldStart = cursor + 4
            let fieldEnd = fieldStart + Int(ZipBytes.uint16(data, cursor + 2))
            guard fieldEnd <= extraRange.upperBound else {
                throw ZipError.invalidCentralDirectory
            }
            if headerId != zip64ExtraFieldId {
                cursor = fieldEnd
                continue
            }

            var result = sizes
            var valueCursor = fieldStart
            func nextValue() throws -> UInt64 {
                guard valueCursor + 8 <= fieldEnd else {
                    throw ZipError.invalidCentralDirectory
                }
                defer { valueCursor += 8 }
                return ZipBytes.uint64(data, valueCursor)
            }
            if result.uncompressed == 0xFFFF_FFFF {
                result.uncompressed = try nextValue()
            }
            if result.compressed == 0xFFFF_FFFF {
                result.compressed = try nextValue()
            }
            if result.localHeaderOffset == 0xFFFF_FFFF {
                result.localHeaderOffset = try nextValue()
            }
            return result
        }
        throw ZipError.invalidCentralDirectory
    }

    /// Mirrors ZIPFoundation's `Entry.type` so the same entries are treated as files, directories or symlinks.
    static func entryType(path: String, versionMadeBy: UInt16, externalAttributes: UInt32) -> ZipEntryType {
        let hostSystem = versionMadeBy >> 8
        let hasDirectorySuffix = path.hasSuffix("/")
        switch hostSystem {
        case 3, 19: // UNIX, macOS
            let mode = mode_t(UInt16(truncatingIfNeeded: externalAttributes >> 16)) & S_IFMT
            switch mode {
            case S_IFREG:
                return .file
            case S_IFDIR:
                return .directory
            case S_IFLNK:
                return .symlink
            default:
                return hasDirectorySuffix ? .directory : .file
            }
        case 0: // MS-DOS
            return hasDirectorySuffix || (externalAttributes >> 4) == 0x01 ? .directory : .file
        default:
            return hasDirectorySuffix ? .directory : .file
        }
    }

    private static let codePage437: String.Encoding = {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        return String.Encoding(rawValue: encoding)
    }()
}

/// Little-endian readers and bounded file reads for ZIP structures.
enum ZipBytes {
    static func readChunk(handle: FileHandle, fileSize: UInt64, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, UInt64(count) <= fileSize, offset <= fileSize - UInt64(count) else {
            throw ZipError.invalidCentralDirectory
        }
        if count == 0 {
            return Data()
        }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZipError.unreadableArchive
        }
        return data
    }

    // Callers bounds-check `offset` against `data.count` before reading.
    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for byteIndex in 0..<4 {
            value |= UInt32(data[base + byteIndex]) << (8 * UInt32(byteIndex))
        }
        return value
    }

    static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for byteIndex in 0..<8 {
            value |= UInt64(data[base + byteIndex]) << (8 * UInt64(byteIndex))
        }
        return value
    }
}
