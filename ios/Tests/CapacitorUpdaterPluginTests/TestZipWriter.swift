import Compression
import Foundation

/// Test-only ZIP writer used to build fixtures for the in-repo ZIP reader.
/// Supports stored and deflate entries, unix modes (directories, symlinks) and optional ZIP64 records.
struct TestZipWriter {
    enum Method: UInt16 {
        case stored = 0
        case deflate = 8
    }

    struct EntrySpec {
        var path: String
        var data: Data
        var method: Method = .stored
        /// Unix mode stored in the high 16 bits of the external attributes (e.g. 0o100644, 0o040755, 0o120777).
        var unixMode: UInt32?
        var generalPurposeFlags: UInt16 = 0x0800 // UTF-8 names
        var forceZip64: Bool = false
        /// Raw name bytes, used instead of the UTF-8 encoding of `path` when set.
        var rawName: Data?
    }

    private(set) var entries: [EntrySpec] = []

    mutating func addFile(_ path: String, _ data: Data, method: Method = .stored, unixMode: UInt32? = 0o100644) {
        entries.append(EntrySpec(path: path, data: data, method: method, unixMode: unixMode))
    }

    mutating func addDirectory(_ path: String) {
        entries.append(EntrySpec(path: path.hasSuffix("/") ? path : "\(path)/", data: Data(), unixMode: 0o040755))
    }

    mutating func addSymlink(_ path: String, target: String, method: Method = .stored) {
        entries.append(EntrySpec(path: path, data: Data(target.utf8), method: method, unixMode: 0o120777))
    }

    mutating func add(_ spec: EntrySpec) {
        entries.append(spec)
    }

    func build(zip64: Bool = false, comment: String = "") -> Data {
        var output = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt64(output.count)
            let record = Record(entry: entry, zip64: zip64 || entry.forceZip64)
            output.append(record.localHeaderAndPayload())
            central.append(record.centralDirectoryEntry(localHeaderOffset: offset))
        }

        let centralOffset = UInt64(output.count)
        output.append(central)
        if zip64 {
            output.append(zip64EndRecords(centralSize: central.count, centralOffset: centralOffset, recordOffset: UInt64(output.count)))
        }

        let commentData = Data(comment.utf8)
        output.appendUInt32(0x0605_4b50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(zip64 ? 0xFFFF : UInt16(entries.count))
        output.appendUInt16(zip64 ? 0xFFFF : UInt16(entries.count))
        output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(central.count))
        output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset))
        output.appendUInt16(UInt16(commentData.count))
        output.append(commentData)
        return output
    }

    private func zip64EndRecords(centralSize: Int, centralOffset: UInt64, recordOffset: UInt64) -> Data {
        var output = Data()
        output.appendUInt32(0x0606_4b50)
        output.appendUInt64(44)
        output.appendUInt16((3 << 8) | 63)
        output.appendUInt16(45)
        output.appendUInt32(0)
        output.appendUInt32(0)
        output.appendUInt64(UInt64(entries.count))
        output.appendUInt64(UInt64(entries.count))
        output.appendUInt64(UInt64(centralSize))
        output.appendUInt64(centralOffset)

        output.appendUInt32(0x0706_4b50)
        output.appendUInt32(0)
        output.appendUInt64(recordOffset)
        output.appendUInt32(1)
        return output
    }

    private struct Record {
        let entry: EntrySpec
        let zip64: Bool
        let nameData: Data
        let payload: Data
        let crc: UInt32

        init(entry: EntrySpec, zip64: Bool) {
            self.entry = entry
            self.zip64 = zip64
            self.nameData = entry.rawName ?? Data(entry.path.utf8)
            self.payload = entry.method == .deflate ? TestZipWriter.deflate(entry.data) : entry.data
            self.crc = TestZipWriter.crc32(entry.data)
        }

        func localHeaderAndPayload() -> Data {
            var extra = Data()
            if zip64 {
                extra.appendUInt16(0x0001)
                extra.appendUInt16(16)
                extra.appendUInt64(UInt64(entry.data.count))
                extra.appendUInt64(UInt64(payload.count))
            }
            var output = Data()
            output.appendUInt32(0x0403_4b50)
            output.appendUInt16(zip64 ? 45 : 20)
            output.appendUInt16(entry.generalPurposeFlags)
            output.appendUInt16(entry.method.rawValue)
            output.appendUInt32(0) // time + date
            output.appendUInt32(crc)
            output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(payload.count))
            output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count))
            output.appendUInt16(UInt16(nameData.count))
            output.appendUInt16(UInt16(extra.count))
            output.append(nameData)
            output.append(extra)
            output.append(payload)
            return output
        }

        func centralDirectoryEntry(localHeaderOffset: UInt64) -> Data {
            var extra = Data()
            if zip64 {
                extra.appendUInt16(0x0001)
                extra.appendUInt16(24)
                extra.appendUInt64(UInt64(entry.data.count))
                extra.appendUInt64(UInt64(payload.count))
                extra.appendUInt64(localHeaderOffset)
            }
            var output = Data()
            output.appendUInt32(0x0201_4b50)
            output.appendUInt16(entry.unixMode != nil ? (3 << 8) | 63 : 20)
            output.appendUInt16(zip64 ? 45 : 20)
            output.appendUInt16(entry.generalPurposeFlags)
            output.appendUInt16(entry.method.rawValue)
            output.appendUInt32(0) // time + date
            output.appendUInt32(crc)
            output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(payload.count))
            output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count))
            output.appendUInt16(UInt16(nameData.count))
            output.appendUInt16(UInt16(extra.count))
            output.appendUInt16(0) // comment length
            output.appendUInt16(0) // disk number
            output.appendUInt16(0) // internal attributes
            output.appendUInt32((entry.unixMode ?? 0) << 16)
            output.appendUInt32(zip64 ? 0xFFFF_FFFF : UInt32(localHeaderOffset))
            output.append(nameData)
            output.append(extra)
            return output
        }
    }

    func write(to url: URL, zip64: Bool = false) throws {
        try build(zip64: zip64).write(to: url)
    }

    /// Raw DEFLATE (RFC 1951) encoding via Apple's Compression framework, streamed so large inputs work.
    static func deflate(_ data: Data) -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            fatalError("compression_stream_init failed")
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        var output = Data()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            // An empty input still needs a valid source pointer.
            var emptyByte: UInt8 = 0
            withUnsafePointer(to: &emptyByte) { emptyPointer in
                stream.pointee.src_ptr = base ?? emptyPointer
                stream.pointee.src_size = data.count
                var status = COMPRESSION_STATUS_OK
                repeat {
                    stream.pointee.dst_ptr = destination
                    stream.pointee.dst_size = bufferSize
                    status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    output.append(destination, count: bufferSize - stream.pointee.dst_size)
                } while status == COMPRESSION_STATUS_OK
                precondition(status == COMPRESSION_STATUS_END, "deflate failed")
            }
        }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
