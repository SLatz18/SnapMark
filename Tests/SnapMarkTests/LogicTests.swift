import XCTest
@testable import SnapMark

final class DriveFolderParserTests: XCTestCase {

    func testBareID() {
        XCTAssertEqual(DriveFolderParser.id(from: "1a2B3c4D5e6F7g8H9i0J"), "1a2B3c4D5e6F7g8H9i0J")
    }

    func testFolderURL() {
        XCTAssertEqual(
            DriveFolderParser.id(from: "https://drive.google.com/drive/folders/1a2B3c4D5e6F7g8H9i0J?usp=sharing"),
            "1a2B3c4D5e6F7g8H9i0J")
    }

    func testIDQueryParam() {
        XCTAssertEqual(
            DriveFolderParser.id(from: "https://drive.google.com/drive/u/0/folders?id=1a2B3c4D5e6F7g8H9i0J"),
            "1a2B3c4D5e6F7g8H9i0J")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(DriveFolderParser.id(from: "  1a2B3c4D5e6F7g8H9i0J\n"), "1a2B3c4D5e6F7g8H9i0J")
    }

    func testRejectsGarbage() {
        XCTAssertNil(DriveFolderParser.id(from: "not a folder!!"))
        XCTAssertNil(DriveFolderParser.id(from: ""))
        XCTAssertNil(DriveFolderParser.id(from: "   "))
        XCTAssertNil(DriveFolderParser.id(from: "short"))
    }
}

final class StampSettingsTests: XCTestCase {

    func testCodableRoundTrip() throws {
        var settings = StampSettings()
        settings.position = .topLeft
        settings.size = .large
        settings.backgroundOpacity = 0.8
        settings.customText = "hello"
        settings.fields[0].enabled = false
        // Reorder: move last field first.
        settings.fields.insert(settings.fields.removeLast(), at: 0)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StampSettings.self, from: data)

        XCTAssertEqual(decoded.position, .topLeft)
        XCTAssertEqual(decoded.size, .large)
        XCTAssertEqual(decoded.backgroundOpacity, 0.8)
        XCTAssertEqual(decoded.customText, "hello")
        XCTAssertEqual(decoded.fields.map(\.field), settings.fields.map(\.field))
        XCTAssertEqual(decoded.fields.map(\.enabled), settings.fields.map(\.enabled))
    }

    func testDefaults() {
        let settings = StampSettings()
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.fields.count, StampField.allCases.count)
        XCTAssertEqual(settings.position, .bottomRight)
        XCTAssertFalse(settings.isFieldEnabled(.customText))
        XCTAssertTrue(settings.isFieldEnabled(.pageURL))
    }
}

final class MetadataTests: XCTestCase {

    private func metadata(pageURL: String? = nil, app: String? = nil) -> ScreenshotMetadata {
        ScreenshotMetadata(
            capturedAt: Date(timeIntervalSince1970: 0),
            userName: "tester",
            fullUserName: "Test User",
            frontAppName: app,
            frontAppBundleID: nil,
            hostName: nil,
            pageURL: pageURL,
            urlCaptureAttempted: false)
    }

    func testFileSourceNameFromHost() {
        XCTAssertEqual(
            metadata(pageURL: "https://example.com/some/page").fileSourceName,
            "example.com")
    }

    func testFileSourceNameFromApp() {
        XCTAssertEqual(metadata(app: "Safari").fileSourceName, "Safari")
    }

    func testFileSourceNameSanitized() {
        // Dots kept for hosts; path separators must go.
        XCTAssertEqual(
            metadata(pageURL: "https://a/b?c").fileSourceName,
            "a")
        XCTAssertEqual(metadata(app: "My App!").fileSourceName, "My_App")
    }

    func testFileSourceNameFallback() {
        XCTAssertEqual(metadata().fileSourceName, "screenshot")
    }
}

#if canImport(FoundationModels)
final class SmartTextTests: XCTestCase {

    func testSanitize() {
        XCTAssertEqual(SmartText.sanitize("\"My Screenshot!.png\""), "My-Screenshot-png")
        XCTAssertEqual(SmartText.sanitize("  quarterly   report___final  "), "quarterly-report-final")
        XCTAssertEqual(SmartText.sanitize("!!!"), "screenshot")
        XCTAssertEqual(SmartText.sanitize(""), "screenshot")
    }

    func testSanitizeKeepsItShort() {
        let long = String(repeating: "a", count: 200)
        XCTAssertLessThanOrEqual(SmartText.sanitize(long).count, 80)
    }
}
#endif
