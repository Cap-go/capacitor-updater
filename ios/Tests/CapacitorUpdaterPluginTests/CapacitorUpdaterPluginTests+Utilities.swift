import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

extension CapacitorUpdaterTests {
    func testDelayUntilNextDescription() {
        XCTAssertEqual(DelayUntilNext.background.description, "background")
        XCTAssertEqual(DelayUntilNext.kill.description, "kill")
        XCTAssertEqual(DelayUntilNext.nativeVersion.description, "nativeVersion")
        XCTAssertEqual(DelayUntilNext.date.description, "date")
    }

    func testDelayUntilNextEncodeDecode() throws {
        let original = DelayUntilNext.background

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DelayUntilNext.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Logger Tests

    func testLoggerInitialization() {
        let logger = Logger(withTag: "TestTag")
        XCTAssertNotNil(logger)

        // Test different log levels
        logger.debug("Debug message")
        logger.info("Info message")
        logger.error("Error message")
        // No assertions here as logger just prints, but we ensure no crashes
    }

    // MARK: - UserDefaults Extension Tests

    func testSetAndGetObject() {
        let testObject = ["key": "value", "number": 42] as [String: Any]
        UserDefaults.standard.set(testObject, forKey: "test_object")

        let retrievedObject = UserDefaults.standard.object(forKey: "test_object") as? [String: Any]
        XCTAssertNotNil(retrievedObject)
        XCTAssertEqual(retrievedObject?["key"] as? String, "value")
        XCTAssertEqual(retrievedObject?["number"] as? Int, 42)

        // Clean up
        UserDefaults.standard.removeObject(forKey: "test_object")
    }

    func testSetAndGetDictionary() {
        let testDict = ["id": "1", "name": "Test"]
        UserDefaults.standard.set(testDict, forKey: "test_dict")

        let retrievedDict = UserDefaults.standard.dictionary(forKey: "test_dict")
        XCTAssertNotNil(retrievedDict)
        XCTAssertEqual(retrievedDict?["id"] as? String, "1")
        XCTAssertEqual(retrievedDict?["name"] as? String, "Test")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "test_dict")
    }

    // MARK: - File System Tests

    func testFileOperations() {
        let testPath = NSTemporaryDirectory().appending("\(UUID().uuidString)-test_file.txt")
        let testContent = "Test content"

        // Test file creation
        let success = FileManager.default.createFile(
            atPath: testPath,
            contents: testContent.data(using: .utf8),
            attributes: nil
        )
        XCTAssertTrue(success)

        // Test file existence
        XCTAssertTrue(FileManager.default.fileExists(atPath: testPath))

        // Test file deletion
        do {
            try FileManager.default.removeItem(atPath: testPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: testPath))
        } catch {
            XCTFail("Failed to delete test file: \(error)")
        }
    }

    // MARK: - Bundle Path Tests

    func testBundlePathGeneration() {
        let bundleId = "test-bundle-123"

        // Generate a mock bundle path
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let bundlePath = documentsPath.appending("/\(bundleId)")

        XCTAssertTrue(bundlePath.contains(bundleId))
        XCTAssertTrue(bundlePath.contains("Documents"))
    }

    // MARK: - Date Extension Tests

    func testDateISO8601Formatting() {
        let date = Date(timeIntervalSince1970: 0)
        let formatted = date.iso8601withFractionalSeconds

        XCTAssertNotNil(formatted)
        XCTAssertTrue(formatted.contains("1970"))
    }

    // MARK: - String Extension Tests

    func testStringTrim() {
        let testString = "  test string  "
        let trimmed = testString.trim()

        XCTAssertEqual(trimmed, "test string")
    }

    func testStringTrimWithNewlines() {
        let testString = "\n\ntest\n\n"
        let trimmed = testString.trim()

        XCTAssertEqual(trimmed, "test")
    }

    // MARK: - CapgoUpdater Tests

    func testCapgoUpdaterInitialization() {
        let updater = CapgoUpdater()
        XCTAssertNotNil(updater)
    }

    func testZipEntryPathRejectsSiblingPrefixPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try CapgoUpdater.resolvePathInsideDirectory(
                baseDirectory: base,
                relativePath: "../bundle-evil/pwned.txt"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle-evil/pwned.txt").path))
    }

    func testManifestTargetPathRejectsPathTraversalAfterBrotliSuffixIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try CapgoUpdater.resolveManifestTargetPath(
                baseDirectory: base,
                fileName: "../bundle-evil/app.js.br"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle-evil/app.js").path))
    }

    func testManifestTargetPathAllowsNestedBrotliFileInsideBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try CapgoUpdater.resolveManifestTargetPath(
            baseDirectory: base,
            fileName: "assets/app.js.br"
        )

        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            base.appendingPathComponent("assets/app.js").standardizedFileURL.path
        )
    }

    // MARK: - Performance Tests

    func testPerformanceStringTrim() {
        let testString = "  test string with spaces  "

        self.measure {
            for _ in 0..<10000 {
                _ = testString.trim()
            }
        }
    }

    func testPerformanceDateFormatting() {
        let date = Date()

        self.measure {
            for _ in 0..<1000 {
                _ = date.iso8601withFractionalSeconds
            }
        }
    }

    func testPerformanceBundleInfoEncoding() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )

        self.measure {
            for _ in 0..<1000 {
                if let data = try? JSONEncoder().encode(bundleInfo) {
                    _ = try? JSONDecoder().decode(BundleInfo.self, from: data)
                }
            }
        }
    }

    func testPerformanceDelayConditionOperations() {
        let condition = DelayCondition(kind: .background, value: "test")

        self.measure {
            for _ in 0..<1000 {
                _ = condition.toJSON()
                _ = condition.toString()
                _ = condition.getKind()
            }
        }
    }
}
