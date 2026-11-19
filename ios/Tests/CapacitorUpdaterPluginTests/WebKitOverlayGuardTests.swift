import XCTest

final class WebKitOverlayGuardTests: XCTestCase {
    func testPluginSourcesAvoidSwiftWebKitOverlayCallAsyncJavaScript() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let pluginSources = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CapacitorUpdaterPlugin", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(
            at: pluginSources,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        var violations: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") {
                    continue
                }
                if line.contains("callAsyncJavaScript("), !line.contains("__callAsyncJavaScript(") {
                    violations.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(violations.isEmpty, "Swift WebKit overlay callAsyncJavaScript found: \(violations.joined(separator: ", "))")
    }
}
