import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin
import ZIPFoundation

final class InstallPerfTests: XCTestCase {
    private let zipFiles = 512
    private let zipFileBytes = 64 * 1024
    private let manifestFiles = 10_000
    private let manifestFileBytes = 2048
    private let runs = 3
    private let oldZipBuffer = 16 * 1024

    func testCompareZipAndManifestInstallBeforeAfter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-install-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zipURL = root.appendingPathComponent("bundle.zip")
        try writeStoredZip(to: zipURL, fileCount: zipFiles, fileBytes: zipFileBytes)
        let zipBytes = (try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue ?? 0
        print("CAPGO_INSTALL_PERF platform=ios fixture=zip files=\(zipFiles) bytes_each=\(zipFileBytes) zip_bytes=\(zipBytes)")

        var unzipBefore: [Int64] = []
        var unzipAfter: [Int64] = []
        for i in 0..<runs {
            unzipBefore.append(try timeUnzip(root: root, zipURL: zipURL, id: "unzip-before-\(i)", bufferSize: oldZipBuffer))
            unzipAfter.append(try timeUnzip(root: root, zipURL: zipURL, id: "unzip-after-\(i)", bufferSize: CryptoCipher.ioBufferBytes()))
        }

        let builtin = root.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
        var sources: [URL] = []
        var hashes: [String] = []
        var payload = Data(repeating: 0x11, count: manifestFileBytes)
        for i in 0..<manifestFiles {
            payload[0] = UInt8(i & 0xff)
            payload[1] = UInt8((i >> 8) & 0xff)
            payload[2] = UInt8((i >> 16) & 0xff)
            let source = builtin.appendingPathComponent("f\(i).js")
            try payload.write(to: source)
            sources.append(source)
            hashes.append(CryptoCipher.calcChecksum(filePath: source))
        }

        var manifestBefore: [Int64] = []
        var manifestAfter: [Int64] = []
        for i in 0..<runs {
            manifestBefore.append(try timeManifestSequential1KiB(root: root, name: "manifest-before-\(i)", sources: sources, hashes: hashes))
            manifestAfter.append(try timeManifestProduction(root: root, name: "manifest-after-\(i)", sources: sources, hashes: hashes))
        }

        printResult(platform: "ios", scenario: "unzip_32mb_512files", before: unzipBefore, after: unzipAfter)
        printResult(platform: "ios", scenario: "manifest_10k_builtin_copy", before: manifestBefore, after: manifestAfter)
    }

    private func timeUnzip(root: URL, zipURL: URL, id: String, bufferSize: Int) throws -> Int64 {
        let updater = CapgoUpdater()
        updater.setLogger(Logger(withTag: "install-perf", options: Logger.Options(level: .silent)))
        let zipCopy = root.appendingPathComponent("\(id).zip")
        try? FileManager.default.removeItem(at: zipCopy)
        try FileManager.default.copyItem(at: zipURL, to: zipCopy)
        let persist = root.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: persist)
        let start = DispatchTime.now().uptimeNanoseconds
        try updater.saveDownloaded(sourceZip: zipCopy, id: id, base: root, notify: false, bufferSize: bufferSize)
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        XCTAssertEqual(zipFiles, try countFiles(in: persist))
        return elapsed
    }

    private func timeManifestProduction(root: URL, name: String, sources: [URL], hashes: [String]) throws -> Int64 {
        let updater = CapgoUpdater()
        updater.setLogger(Logger(withTag: "install-perf", options: Logger.Options(level: .silent)))
        let destDir = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destDir)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let files = Swift.zip(sources, hashes).map { source, hash in
            (source: source, dest: destDir.appendingPathComponent(source.lastPathComponent), hash: hash)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        try updater.copyMatchingBuiltinFilesForTests(files: files)
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        XCTAssertEqual(manifestFiles, try countFiles(in: destDir))
        return elapsed
    }

    private func timeManifestSequential1KiB(root: URL, name: String, sources: [URL], hashes: [String]) throws -> Int64 {
        let destDir = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destDir)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = CapgoUpdater.manifestMaxConcurrentFiles
        let start = DispatchTime.now().uptimeNanoseconds
        let lock = NSLock()
        var firstError: Error?
        for (source, hash) in Swift.zip(sources, hashes) {
            queue.addOperation {
                do {
                    let actual = Self.sha256OneKiB(file: source)
                    guard actual.lowercased() == hash.lowercased() else {
                        throw NSError(domain: "CapgoInstallPerf", code: 3, userInfo: [NSLocalizedDescriptionKey: "checksum mismatch"])
                    }
                    let dest = destDir.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: dest)
                } catch {
                    lock.lock()
                    if firstError == nil {
                        firstError = error
                    }
                    lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if let firstError {
            throw firstError
        }
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        XCTAssertEqual(manifestFiles, try countFiles(in: destDir))
        return elapsed
    }

    private func printResult(platform: String, scenario: String, before: [Int64], after: [Int64]) {
        print(
            "CAPGO_INSTALL_PERF platform=\(platform) scenario=\(scenario) before_ms=\(median(before)) after_ms=\(median(after)) before_runs=\(before) after_runs=\(after)"
        )
    }

    private func median(_ values: [Int64]) -> Int64 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func writeStoredZip(to zipURL: URL, fileCount: Int, fileBytes: Int) throws {
        let archive = try Archive(url: zipURL, accessMode: .create)
        for i in 0..<fileCount {
            var payload = Data(repeating: UInt8(i & 0xff), count: fileBytes)
            payload[0] = UInt8(i & 0xff)
            payload[1] = UInt8((i >> 8) & 0xff)
            try archive.addEntry(
                with: "www/f\(i).js",
                type: .file,
                uncompressedSize: Int64(payload.count),
                compressionMethod: .none,
                bufferSize: CryptoCipher.ioBufferBytes(),
                provider: { position, size in
                    let start = Int(position)
                    return payload.subdata(in: start..<(start + size))
                }
            )
        }
    }

    private func countFiles(in dir: URL) throws -> Int {
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        var count = 0
        for entry in entries {
            let isDir = (try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                count += try countFiles(in: entry)
            } else {
                count += 1
            }
        }
        return count
    }

    private static func sha256OneKiB(file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ""
        }
        defer { try? handle.close() }
        var hasher = CryptoCipher.RunningChecksum()
        while true {
            let chunk = (try? handle.read(upToCount: 1024)) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(chunk)
        }
        return hasher.hex()
    }
}
