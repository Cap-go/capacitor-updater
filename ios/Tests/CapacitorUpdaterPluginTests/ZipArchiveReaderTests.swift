import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

final class ZipArchiveReaderTests: XCTestCase {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-zip-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func writeZip(_ writer: TestZipWriter, name: String = "test.zip", zip64: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        try writer.write(to: url, zip64: zip64)
        return url
    }

    private func readAll(_ reader: ZipArchiveReader, _ entry: ZipEntry, bufferSize: Int = 4096) throws -> Data {
        var data = Data()
        try reader.extract(entry, bufferSize: bufferSize) { chunk in
            XCTAssertLessThanOrEqual(chunk.count, bufferSize)
            data.append(chunk)
        }
        return data
    }

    private func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func compressibleData(count: Int) -> Data {
        let pattern = Data("capgo-live-update-".utf8)
        var data = Data(capacity: count)
        while data.count < count {
            data.append(pattern)
        }
        return data.prefix(count)
    }

    // MARK: - Reader

    func testReadsStoredAndDeflatedEntries() throws {
        let stored = randomData(count: 10_000)
        let deflated = compressibleData(count: 300_000)
        let empty = Data()
        var writer = TestZipWriter()
        writer.addFile("stored.bin", stored)
        writer.addFile("deflated.txt", deflated, method: .deflate)
        writer.addFile("empty-stored.txt", empty)
        writer.addFile("empty-deflated.txt", empty, method: .deflate)
        let reader = try ZipArchiveReader(url: try writeZip(writer))

        XCTAssertEqual(reader.entries.map(\.path), ["stored.bin", "deflated.txt", "empty-stored.txt", "empty-deflated.txt"])
        XCTAssertTrue(reader.entries.allSatisfy { $0.type == .file })
        XCTAssertEqual(try readAll(reader, reader.entries[0]), stored)
        XCTAssertEqual(try readAll(reader, reader.entries[1]), deflated)
        XCTAssertEqual(try readAll(reader, reader.entries[1], bufferSize: 7), deflated)
        XCTAssertEqual(try readAll(reader, reader.entries[2]), empty)
        XCTAssertEqual(try readAll(reader, reader.entries[3]), empty)
    }

    func testReadsIncompressibleDeflatedEntryWithSmallBuffer() throws {
        let payload = randomData(count: 200_000)
        var writer = TestZipWriter()
        writer.addFile("random.bin", payload, method: .deflate)
        let reader = try ZipArchiveReader(url: try writeZip(writer))
        XCTAssertEqual(try readAll(reader, reader.entries[0], bufferSize: 1024), payload)
    }

    func testDetectsDirectoriesAndSymlinks() throws {
        var writer = TestZipWriter()
        writer.addDirectory("assets")
        writer.addFile("assets/app.js", Data("js".utf8))
        writer.addSymlink("assets/link.js", target: "app.js")
        // DOS-style entry: directory detected from the trailing slash only.
        writer.add(TestZipWriter.EntrySpec(path: "legacy/", data: Data(), unixMode: nil))
        let reader = try ZipArchiveReader(url: try writeZip(writer))

        XCTAssertEqual(reader.entries.map(\.type), [.directory, .file, .symlink, .directory])
        XCTAssertEqual(try readAll(reader, reader.entries[0]), Data())
        XCTAssertEqual(try reader.readSmallEntry(reader.entries[2], maxBytes: 1024, bufferSize: 16), Data("app.js".utf8))
    }

    func testEntryTypeMatchesPreviousZipFoundationRules() {
        let unix: UInt16 = 3 << 8
        let macOS: UInt16 = 19 << 8
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a", versionMadeBy: unix, externalAttributes: 0o100644 << 16), .file)
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a", versionMadeBy: unix, externalAttributes: 0o040755 << 16), .directory)
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a", versionMadeBy: macOS, externalAttributes: 0o120777 << 16), .symlink)
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a/", versionMadeBy: unix, externalAttributes: 0), .directory)
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a", versionMadeBy: 0, externalAttributes: 0x10), .directory)
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a", versionMadeBy: 0, externalAttributes: 0x20), .file)
        // Symlink mode bits from a non-unix host are ignored.
        XCTAssertEqual(ZipCentralDirectory.entryType(path: "a", versionMadeBy: 0, externalAttributes: 0o120777 << 16), .file)
    }

    func testDecodesUtf8AndCp437Names() throws {
        var writer = TestZipWriter()
        writer.addFile("caf\u{E9}.txt", Data("utf8".utf8))
        // Without the UTF-8 flag names are CP437, where 0x82 is "é".
        var cp437 = TestZipWriter.EntrySpec(path: "", data: Data("cp437".utf8))
        cp437.generalPurposeFlags = 0
        cp437.rawName = Data([0x82, 0x2E, 0x74, 0x78, 0x74])
        writer.add(cp437)

        let reader = try ZipArchiveReader(url: try writeZip(writer))
        XCTAssertEqual(reader.entries.map(\.path), ["caf\u{E9}.txt", "\u{E9}.txt"])
    }

    func testReadsZip64Archive() throws {
        let payload = compressibleData(count: 50_000)
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8))
        writer.addFile("big.js", payload, method: .deflate)
        let reader = try ZipArchiveReader(url: try writeZip(writer, zip64: true))
        XCTAssertEqual(reader.entries.map(\.path), ["index.html", "big.js"])
        XCTAssertEqual(reader.entries[1].uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(try readAll(reader, reader.entries[1]), payload)
    }

    func testFindsEndOfCentralDirectoryBeforeComment() throws {
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("hi".utf8))
        let url = root.appendingPathComponent("comment.zip")
        try writer.build(comment: "PK\u{05}\u{06} trailing comment").write(to: url)
        let reader = try ZipArchiveReader(url: url)
        XCTAssertEqual(try readAll(reader, reader.entries[0]), Data("hi".utf8))
    }

    func testRejectsEncryptedEntries() throws {
        var writer = TestZipWriter()
        var spec = TestZipWriter.EntrySpec(path: "secret.txt", data: Data("secret".utf8))
        spec.generalPurposeFlags = 0x0801
        writer.add(spec)
        let reader = try ZipArchiveReader(url: try writeZip(writer))
        XCTAssertThrowsError(try readAll(reader, reader.entries[0])) { error in
            XCTAssertEqual(error as? ZipError, .encryptedEntry)
        }
    }

    func testRejectsUnsupportedCompressionMethod() throws {
        var writer = TestZipWriter()
        writer.addFile("file.txt", Data("abc".utf8))
        var data = writer.build()
        // Local header method is at offset 8; set it to 12 (bzip2).
        data[8] = 12
        let url = root.appendingPathComponent("bzip2.zip")
        try data.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        XCTAssertThrowsError(try readAll(reader, reader.entries[0])) { error in
            XCTAssertEqual(error as? ZipError, .unsupportedCompressionMethod(12))
        }
    }

    func testRejectsInvalidBufferSize() throws {
        var writer = TestZipWriter()
        writer.addFile("file.txt", Data("abc".utf8))
        let reader = try ZipArchiveReader(url: try writeZip(writer))
        XCTAssertThrowsError(try reader.extract(reader.entries[0], bufferSize: 0) { _ in
            // No chunk is expected: the buffer size is rejected before reading.
        }) { error in
            XCTAssertEqual(error as? ZipError, .invalidBufferSize)
        }
    }

    func testCorruptArchivesThrowInsteadOfCrashing() throws {
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8))
        writer.addFile("app.js", compressibleData(count: 20_000), method: .deflate)
        let valid = writer.build()

        var candidates: [Data] = [
            Data(),
            Data("not a zip".utf8),
            Data(repeating: 0, count: 22),
            valid.prefix(valid.count / 2),
            valid.suffix(40)
        ]
        // Truncate at every offset and flip bytes in every header byte range.
        for length in stride(from: 0, to: valid.count, by: 97) {
            candidates.append(valid.prefix(length))
        }
        for index in 0..<valid.count where index < 120 || index >= valid.count - 160 {
            var mutated = valid
            mutated[index] ^= 0xFF
            candidates.append(mutated)
        }

        for (index, candidate) in candidates.enumerated() {
            let url = root.appendingPathComponent("corrupt-\(index).zip")
            try candidate.write(to: url)
            // Either the archive fails to open or every entry either extracts or throws. Nothing may crash or hang.
            guard let reader = try? ZipArchiveReader(url: url) else {
                continue
            }
            for entry in reader.entries {
                _ = try? reader.readSmallEntry(entry, maxBytes: 1_000_000, bufferSize: 512)
            }
        }
    }

    func testRejectsCentralDirectoryPointingOutsideArchive() throws {
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8))
        var data = writer.build()
        // EOCD central directory offset lives 16 bytes into the 22-byte EOCD record.
        let offsetIndex = data.count - 22 + 16
        data[offsetIndex] = 0xFF
        data[offsetIndex + 1] = 0xFF
        data[offsetIndex + 2] = 0xFF
        data[offsetIndex + 3] = 0x7F
        let url = root.appendingPathComponent("bad-offset.zip")
        try data.write(to: url)
        XCTAssertThrowsError(try ZipArchiveReader(url: url))
    }

    func testRejectsLocalHeaderOffsetOutsideArchive() throws {
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8))
        var data = writer.build()
        // Central directory entry starts right after the only local entry; its local header offset is at +42.
        let centralStart = 30 + "index.html".utf8.count + "<html></html>".utf8.count
        data[centralStart + 42] = 0xFF
        data[centralStart + 43] = 0xFF
        data[centralStart + 44] = 0xFF
        data[centralStart + 45] = 0x7F
        let url = root.appendingPathComponent("bad-local.zip")
        try data.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        XCTAssertThrowsError(try readAll(reader, reader.entries[0]))
    }

    func testRejectsDeflatedOutputThatDiffersFromDeclaredSize() throws {
        let payload = compressibleData(count: 100_000)
        for declaredSize: UInt32 in [10, 200_000] {
            var writer = TestZipWriter()
            writer.addFile("app.js", payload, method: .deflate)
            var data = writer.build()
            // Patch the central directory's uncompressed size (offset 24 in the central header).
            let signature = Data([0x50, 0x4B, 0x01, 0x02])
            guard let range = data.range(of: signature) else {
                return XCTFail("central directory not found")
            }
            var littleEndian = declaredSize.littleEndian
            let sizeBytes = Data(bytes: &littleEndian, count: 4)
            data.replaceSubrange((range.lowerBound + 24)..<(range.lowerBound + 28), with: sizeBytes)
            let url = root.appendingPathComponent("size-\(declaredSize).zip")
            try data.write(to: url)
            let reader = try ZipArchiveReader(url: url)
            XCTAssertThrowsError(try readAll(reader, reader.entries[0])) { error in
                XCTAssertEqual(error as? ZipError, .corruptedEntryData)
            }
        }
    }

    func testRejectsTruncatedDeflateStream() throws {
        let payload = compressibleData(count: 100_000)
        var writer = TestZipWriter()
        writer.addFile("app.js", payload, method: .deflate)
        var data = writer.build()
        // Corrupt the deflate payload (starts right after the 30-byte local header and the name).
        let payloadStart = 30 + "app.js".utf8.count
        for index in payloadStart..<(payloadStart + 8) {
            data[index] = 0xFF
        }
        let url = root.appendingPathComponent("bad-deflate.zip")
        try data.write(to: url)
        let reader = try ZipArchiveReader(url: url)
        XCTAssertThrowsError(try readAll(reader, reader.entries[0]))
    }
}
