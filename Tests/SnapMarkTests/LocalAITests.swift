import XCTest
@testable import SnapMark

/// Unit tests for the on-device PII redaction logic in LocalAI.
/// These run with `swift test` (via ./build.sh) — no camera, no network.
final class LocalAITests: XCTestCase {

    private func line(_ text: String) -> LocalAI.TextLine {
        // 1000x200 line box, top-left origin.
        LocalAI.TextLine(text: text, box: CGRect(x: 0, y: 0, width: 1000, height: 200))
    }

    // MARK: - Credit cards (Luhn)

    func testLuhnValidCards() {
        XCTAssertTrue(LocalAI.isCardNumber("4111 1111 1111 1111"))
        XCTAssertTrue(LocalAI.isCardNumber("5500-0000-0000-0004"))
        XCTAssertTrue(LocalAI.isCardNumber("378282246310005"))
    }

    func testLuhnInvalidCards() {
        XCTAssertFalse(LocalAI.isCardNumber("4111 1111 1111 1112"))
        XCTAssertFalse(LocalAI.isCardNumber("1234"))
        XCTAssertFalse(LocalAI.isCardNumber("not a number"))
    }

    // MARK: - Pattern detection

    func testDetectsEmail() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("Contact me at jane.doe@example.com today")])
        XCTAssertFalse(boxes.isEmpty, "email should be detected")
    }

    func testDetectsPhone() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("Call (512) 555-0147 now")])
        XCTAssertFalse(boxes.isEmpty, "phone number should be detected")
    }

    func testIgnoresDateLikeDigits() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("Meeting on 2026-09-21 at noon")])
        XCTAssertTrue(boxes.isEmpty, "a date must not be treated as a phone number")
    }

    func testDetectsCardNumber() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("Card 4111 1111 1111 1111 expired")])
        XCTAssertFalse(boxes.isEmpty, "valid card number should be detected")
    }

    func testIgnoresInvalidCardNumber() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("Card 4111 1111 1111 1112 expired")])
        XCTAssertTrue(boxes.isEmpty, "Luhn-invalid number must not be detected")
    }

    func testDetectsAPIKeys() {
        for key in ["sk-abcdefghijklmnopqrst", "AKIAIOSFODNN7EXAMPLE", "ghp_abcdefghijklmnop"] {
            let boxes = LocalAI.sensitiveBoxes(in: [line("token=\(key)")])
            XCTAssertFalse(boxes.isEmpty, "\(key) should be detected")
        }
    }

    func testDetectsPersonName() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("Signed, John Appleseed")])
        XCTAssertFalse(boxes.isEmpty, "person name should be detected by NER")
    }

    func testCleanTextProducesNoBoxes() {
        let boxes = LocalAI.sensitiveBoxes(in: [line("The quick brown fox jumps over the lazy dog")])
        XCTAssertTrue(boxes.isEmpty, "ordinary text must not be redacted")
    }

    // MARK: - Geometry

    func testEstimatedBoxStaysInsideLine() {
        let l = line("email jane.doe@example.com here")
        let boxes = LocalAI.sensitiveBoxes(in: [l])
        XCTAssertEqual(boxes.count, 1)
        // Generous padding is fine, but it shouldn't explode.
        XCTAssertTrue(boxes[0].width < l.box.width)
        XCTAssertTrue(boxes[0].height >= l.box.height)
    }

    func testMergeOverlapping() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 50, width: 100, height: 100)
        let c = CGRect(x: 500, y: 500, width: 50, height: 50)
        let merged = LocalAI.mergeOverlapping([a, b, c])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(a.union(b)))
        XCTAssertTrue(merged.contains(c))
    }

    func testDenormalizeFlipsY() {
        // Vision: bottom-left origin. Image 200x100, box at normalized
        // (0.25, 0.5, w 0.5, h 0.25) -> pixels x=50, y=25, w=100, h=25.
        let box = LocalAI.denormalize(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
                                      width: 200, height: 100)
        XCTAssertEqual(box, CGRect(x: 50, y: 25, width: 100, height: 25), accuracy: 0.001)
    }
}

private func XCTAssertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.origin.x, b.origin.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.origin.y, b.origin.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
}
