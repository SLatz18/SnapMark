import XCTest
@testable import SnapMark

/// Unit tests for the Excalidraw-style annotation model: bounding boxes,
/// moves, resizes, selection, and transform undo.
final class AnnotationTransformTests: XCTestCase {

    private func rectAnn() -> Annotation {
        Annotation(kind: .rect(CGRect(x: 10, y: 20, width: 100, height: 50), filled: false),
                   color: .palette[0], width: 4)
    }

    // MARK: - Bounding boxes

    func testRectBoundingBox() {
        let box = rectAnn().boundingBox(sketch: false)
        XCTAssertEqual(box, CGRect(x: 7, y: 17, width: 106, height: 56))
    }

    func testArrowBoundingBoxPadsByWidth() {
        let a = Annotation(kind: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)),
                           color: .palette[0], width: 8)
        let box = a.boundingBox(sketch: false)
        XCTAssertEqual(box.minX, -7, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 107, accuracy: 0.001)
    }

    func testTextBoundingBoxNonEmpty() {
        let a = Annotation(kind: .text(at: CGPoint(x: 5, y: 5), string: "hello"),
                           color: .palette[0], width: 4, fontSize: 24)
        let box = a.boundingBox(sketch: false)
        XCTAssertEqual(box.origin.x, 5, accuracy: 0.001)
        XCTAssertEqual(box.origin.y, 5, accuracy: 0.001)
        XCTAssertGreaterThan(box.width, 10)
        XCTAssertGreaterThan(box.height, 10)
    }

    func testPenBoundingBox() {
        let pts = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40), CGPoint(x: 20, y: 25)]
        let a = Annotation(kind: .pen(points: pts), color: .palette[0], width: 4)
        let box = a.boundingBox(sketch: false)
        XCTAssertEqual(box.minX, 10 - 4, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 30 + 4, accuracy: 0.001)
        XCTAssertEqual(box.minY, 10 - 4, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 40 + 4, accuracy: 0.001)
    }

    // MARK: - Moves

    func testMoveRect() {
        let moved = rectAnn().moved(by: CGPoint(x: 5, y: -10))
        guard case .rect(let r, _) = moved.kind else { return XCTFail() }
        XCTAssertEqual(r, CGRect(x: 15, y: 10, width: 100, height: 50))
    }

    func testMoveArrow() {
        let a = Annotation(kind: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)),
                           color: .palette[0], width: 4)
        let moved = a.moved(by: CGPoint(x: 3, y: 3))
        guard case .arrow(let f, let t) = moved.kind else { return XCTFail() }
        XCTAssertEqual(f.x, 3, accuracy: 0.001)
        XCTAssertEqual(t.x, 13, accuracy: 0.001)
    }

    // MARK: - Resizes

    func testResizeRect() {
        let a = rectAnn()
        let old = a.boundingBox(sketch: false)
        // Double the selection box: the rect should double too.
        let new = CGRect(x: old.minX, y: old.minY,
                         width: old.width * 2, height: old.height * 2)
        let resized = a.resized(from: old, to: new)
        guard case .rect(let r, _) = resized.kind else { return XCTFail() }
        XCTAssertEqual(r.width, 200, accuracy: 0.5)
        XCTAssertEqual(r.height, 100, accuracy: 0.5)
    }

    func testResizeTextScalesFont() {
        let a = Annotation(kind: .text(at: CGPoint(x: 0, y: 0), string: "hi"),
                           color: .palette[0], width: 4, fontSize: 24)
        let old = a.boundingBox(sketch: false)
        let new = CGRect(x: old.minX, y: old.minY,
                         width: old.width * 2, height: old.height * 2)
        let resized = a.resized(from: old, to: new)
        XCTAssertEqual(resized.fontSize, 48, accuracy: 0.5)
    }

    func testResizeDegenerateBoxFallsBackToTranslate() {
        // A horizontal line has zero-height box; resizing must not explode.
        let a = Annotation(kind: .line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50)),
                           color: .palette[0], width: 4)
        let resized = a.resized(from: .zero,
                                to: CGRect(x: 10, y: 10, width: 50, height: 50))
        guard case .line(let f, let t) = resized.kind else { return XCTFail() }
        XCTAssertEqual(f.x, 10, accuracy: 0.001)
        XCTAssertEqual(t.x, 110, accuracy: 0.001)
    }

    // MARK: - Selection & history (needs an NSImage; macOS only)

    private func makeDocument() -> AnnotationDocument? {
        let size = NSSize(width: 400, height: 300)
        let image = NSImage(size: size, flipped: true)
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let meta = ScreenshotMetadata(
            capturedAt: Date(), userName: "tester", fullUserName: "Tester",
            frontAppName: nil, frontAppBundleID: nil, hostName: nil,
            pageURL: nil, urlCaptureAttempted: false)
        return AnnotationDocument(image: image, metadata: meta)
    }

    func testSelectInRectAndDeleteUndo() throws {
        let doc = try XCTUnwrap(makeDocument())
        doc.addAnnotation(rectAnn())
        doc.addAnnotation(Annotation(kind: .ellipse(CGRect(x: 300, y: 200, width: 40, height: 40), filled: false),
                                     color: .palette[0], width: 4))

        doc.selectInRect(CGRect(x: 0, y: 0, width: 200, height: 200), additive: false)
        XCTAssertEqual(doc.selection.count, 1)

        doc.deleteSelection()
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertTrue(doc.selection.isEmpty)

        doc.undo()
        XCTAssertEqual(doc.annotations.count, 2)
        doc.redo()
        XCTAssertEqual(doc.annotations.count, 1)
    }

    func testTransformUndoRoundTrip() throws {
        let doc = try XCTUnwrap(makeDocument())
        let before = rectAnn()
        doc.addAnnotation(before)

        doc.selection = [before.id]
        let snap = doc.snapshotForTransform(ids: doc.selection)
        doc.applyMove(snapshot: snap, delta: CGPoint(x: 20, y: 30))
        doc.commitTransform(snapshot: snap)

        guard case .rect(let movedR, _) = doc.annotations[0].kind else { return XCTFail() }
        XCTAssertEqual(movedR.origin.x, 30, accuracy: 0.001)

        doc.undo()
        guard case .rect(let undoneR, _) = doc.annotations[0].kind else { return XCTFail() }
        XCTAssertEqual(undoneR.origin.x, 10, accuracy: 0.001)

        doc.redo()
        guard case .rect(let redoneR, _) = doc.annotations[0].kind else { return XCTFail() }
        XCTAssertEqual(redoneR.origin.x, 30, accuracy: 0.001)
    }

    func testBlurNotSelectable() throws {
        let doc = try XCTUnwrap(makeDocument())
        let image = try XCTUnwrap(doc.cgImageForAI())
        let patch = try XCTUnwrap(
            AnnotationRenderer.pixellatedPatch(of: image, rect: CGRect(x: 10, y: 10, width: 50, height: 50)))
        doc.addAnnotation(Annotation(kind: .blur(rect: CGRect(x: 10, y: 10, width: 50, height: 50), patch: patch),
                                     color: .palette[0], width: 0))
        doc.selectInRect(CGRect(x: 0, y: 0, width: 400, height: 300), additive: false)
        XCTAssertTrue(doc.selection.isEmpty, "blur must never be selectable")
        doc.selectAll()
        XCTAssertTrue(doc.selection.isEmpty)
    }

    // MARK: - Diamond hit testing

    func testDiamondHit() {
        let a = Annotation(kind: .diamond(CGRect(x: 0, y: 0, width: 100, height: 100), filled: true),
                           color: .palette[0], width: 4)
        // Center is inside the diamond.
        XCTAssertNotNil(AnnotationRenderer.hitTest([a], at: CGPoint(x: 50, y: 50), sketch: false))
        // Corner of the bounding box is outside the diamond.
        XCTAssertNil(AnnotationRenderer.hitTest([a], at: CGPoint(x: 2, y: 2), sketch: false))
    }
}
