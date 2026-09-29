import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// End-to-end extraction through `CapgoUpdater.saveDownloaded`, including the path traversal guards.
final class ZipBundleExtractionTests: XCTestCase {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-zip-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeZip(_ writer: TestZipWriter, name: String = "test.zip") throws -> URL {
        let url = root.appendingPathComponent(name)
        try writer.write(to: url)
        return url
    }

    private func makeUpdater() -> CapgoUpdater {
        let updater = CapgoUpdater()
        updater.setLogger(Logger(withTag: "zip-extract-tests", options: Logger.Options(level: .silent)))
        return updater
    }

    private func compressibleData(count: Int) -> Data {
        let pattern = Data("capgo-live-update-".utf8)
        var data = Data(capacity: count)
        while data.count < count {
            data.append(pattern)
        }
        return data.prefix(count)
    }

    func testSaveDownloadedExtractsNestedFilesDirectoriesAndSymlinks() throws {
        let appJs = compressibleData(count: 120_000)
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8), method: .deflate)
        writer.addDirectory("assets")
        writer.addFile("assets/app.js", appJs, method: .deflate)
        writer.addFile("assets/deep/nested/data.bin", Data([1, 2, 3]))
        writer.addSymlink("assets/alias.js", target: "app.js")
        let zipURL = try writeZip(writer)

        let base = root.appendingPathComponent("bundles")
        try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "bundle1", base: base, notify: false, bufferSize: 4096)

        let bundle = base.appendingPathComponent("bundle1")
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("index.html")), Data("<html></html>".utf8))
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("assets/app.js")), appJs)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("assets/deep/nested/data.bin")), Data([1, 2, 3]))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: bundle.appendingPathComponent("assets/alias.js").path),
            "app.js"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path), "source zip is removed after extraction")
    }

    func testSaveDownloadedUnflattensSingleTopLevelFolder() throws {
        var writer = TestZipWriter()
        writer.addDirectory("dist")
        writer.addFile("dist/index.html", Data("<html></html>".utf8))
        let zipURL = try writeZip(writer)
        let base = root.appendingPathComponent("bundles")
        try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "bundle2", base: base, notify: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("bundle2/index.html").path))
    }

    func testSaveDownloadedRejectsPathTraversalEntries() throws {
        let maliciousPaths = [
            "../escape.txt",
            "assets/../../escape.txt",
            "/tmp/capgo-absolute-escape.txt",
            "..\\escape.txt",
            "./../escape.txt"
        ]
        for (index, path) in maliciousPaths.enumerated() {
            var writer = TestZipWriter()
            writer.addFile("index.html", Data("<html></html>".utf8))
            writer.addFile(path, Data("pwned".utf8))
            let zipURL = try writeZip(writer, name: "traversal-\(index).zip")
            let base = root.appendingPathComponent("bundles-\(index)")

            XCTAssertThrowsError(
                try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "evil", base: base, notify: false),
                "entry \(path) must be rejected"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("evil").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.txt").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/capgo-absolute-escape.txt"))
    }

    func testSaveDownloadedRejectsEscapingSymlinks() throws {
        let targets = ["../../outside", "/etc/passwd", "../../../../../../etc/hosts"]
        for (index, target) in targets.enumerated() {
            var writer = TestZipWriter()
            writer.addFile("index.html", Data("<html></html>".utf8))
            writer.addSymlink("assets/link", target: target)
            let zipURL = try writeZip(writer, name: "symlink-\(index).zip")
            let base = root.appendingPathComponent("symlink-bundles-\(index)")
            XCTAssertThrowsError(
                try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "evil", base: base, notify: false),
                "symlink target \(target) must be rejected"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("evil").path))
        }
    }

    func testSaveDownloadedRejectsCorruptZip() throws {
        let zipURL = root.appendingPathComponent("corrupt.zip")
        try Data("definitely not a zip file".utf8).write(to: zipURL)
        let base = root.appendingPathComponent("bundles")
        XCTAssertThrowsError(try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "broken", base: base, notify: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("broken").path))
    }
}
