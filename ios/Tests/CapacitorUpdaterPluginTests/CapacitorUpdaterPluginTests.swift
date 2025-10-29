import XCTest
@testable import CapacitorUpdaterPlugin

class CapacitorUpdaterTests: XCTestCase {

    var plugin: CapacitorUpdaterPlugin!
    var implementation: CapgoUpdater!

    override func setUp() {
        super.setUp()
        plugin = CapacitorUpdaterPlugin()
        implementation = CapgoUpdater()
    }

    override func tearDown() {
        plugin = nil
        implementation = nil
        super.tearDown()
    }

    // MARK: - BundleInfo Tests

    func testBundleInfoInitialization() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "abc123"
        )

        XCTAssertEqual(bundleInfo.getId(), "test-id")
        XCTAssertEqual(bundleInfo.getVersionName(), "1.0.0")
        XCTAssertEqual(bundleInfo.getStatus(), "pending")
        XCTAssertEqual(bundleInfo.getChecksum(), "abc123")
    }

    func testBundleInfoBuiltin() {
        let bundleInfo = BundleInfo(
            id: BundleInfo.ID_BUILTIN,
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: BundleInfo.DOWNLOADED_BUILTIN,
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isBuiltin())
        XCTAssertFalse(bundleInfo.isUnknown())
    }

    func testBundleInfoUnknown() {
        let bundleInfo = BundleInfo(
            id: BundleInfo.VERSION_UNKNOWN,
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: BundleInfo.DOWNLOADED_BUILTIN,
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isUnknown())
        XCTAssertFalse(bundleInfo.isBuiltin())
    }

    func testBundleInfoErrorStatus() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .ERROR,
            downloaded: Date(),
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isErrorStatus())
        XCTAssertFalse(bundleInfo.isDeleted())
    }

    func testBundleInfoDeletedStatus() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .DELETED,
            downloaded: Date(),
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isDeleted())
        XCTAssertFalse(bundleInfo.isErrorStatus())
    }

    func testBundleInfoEncodeDecode() throws {
        let originalBundle = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalBundle)

        // Decode
        let decoder = JSONDecoder()
        let decodedBundle = try decoder.decode(BundleInfo.self, from: data)

        XCTAssertEqual(decodedBundle.getId(), originalBundle.getId())
        XCTAssertEqual(decodedBundle.getVersionName(), originalBundle.getVersionName())
        XCTAssertEqual(decodedBundle.getStatus(), originalBundle.getStatus())
        XCTAssertEqual(decodedBundle.getChecksum(), originalBundle.getChecksum())
    }

    // MARK: - BundleStatus Tests

    func testBundleStatusLocalization() {
        XCTAssertEqual(BundleStatus.SUCCESS.localizedString, "success")
        XCTAssertEqual(BundleStatus.ERROR.localizedString, "error")
        XCTAssertEqual(BundleStatus.PENDING.localizedString, "pending")
        XCTAssertEqual(BundleStatus.DELETED.localizedString, "deleted")
        XCTAssertEqual(BundleStatus.DOWNLOADING.localizedString, "downloading")
    }

    func testBundleStatusFromLocalizedString() {
        XCTAssertEqual(BundleStatus(localizedString: "success"), BundleStatus.SUCCESS)
        XCTAssertEqual(BundleStatus(localizedString: "error"), BundleStatus.ERROR)
        XCTAssertEqual(BundleStatus(localizedString: "pending"), BundleStatus.PENDING)
        XCTAssertEqual(BundleStatus(localizedString: "deleted"), BundleStatus.DELETED)
        XCTAssertEqual(BundleStatus(localizedString: "downloading"), BundleStatus.DOWNLOADING)
        XCTAssertNil(BundleStatus(localizedString: "invalid"))
    }

    // MARK: - DelayCondition Tests

    func testDelayConditionInitialization() {
        let condition = DelayCondition(kind: .background, value: "test-value")

        XCTAssertEqual(condition.getKind(), "background")
        XCTAssertEqual(condition.getValue(), "test-value")
    }

    func testDelayConditionWithStringInit() {
        let condition = DelayCondition(kind: "kill", value: "test-value")

        XCTAssertEqual(condition.getKind(), "kill")
        XCTAssertEqual(condition.getValue(), "test-value")
    }

    func testDelayConditionToJSON() {
        let condition = DelayCondition(kind: .nativeVersion, value: "1.0.0")
        let json = condition.toJSON()

        XCTAssertEqual(json["kind"], "nativeVersion")
        XCTAssertEqual(json["value"], "1.0.0")
    }

    func testDelayConditionEquality() {
        let condition1 = DelayCondition(kind: .date, value: "2023-01-01")
        let condition2 = DelayCondition(kind: .date, value: "2023-01-01")
        let condition3 = DelayCondition(kind: .date, value: "2023-01-02")

        XCTAssertTrue(condition1 == condition2)
        XCTAssertFalse(condition1 == condition3)
    }

    // MARK: - DelayUntilNext Tests

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
        let testPath = NSTemporaryDirectory().appending("test_file.txt")
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
