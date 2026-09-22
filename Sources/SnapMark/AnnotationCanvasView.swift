import AppKit
import SwiftUI

/// The drawing surface. A flipped AppKit view (origin top-left) so mouse
/// coordinates, image pixels, and the export path all share one space.
final class AnnotationCanvasView: NSView {
    var document: AnnotationDocument!

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        AnnotationRenderer.draw(base: document.baseImage,
                                annotations: document.annotations,
                                draftShape: document.draftShape,
                                draftBlur: document.draftBlurRect,
                                draftSpotlight: document.draftSpotlightRect,
                                draftCrop: document.draftCropRect,
                                sketch: document.sketchStyle,
                                in: ctx,
                                bounds: bounds,
                                selection: document.selection,
                                marquee: document.marqueeRect)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc first clears an active marquee/selection, then closes the editor
        // (the text field consumes Esc while editing).
        if document.marqueeRect != nil {
            document.marqueeRect = nil
            needsDisplay = true
            return
        }
        if !document.selection.isEmpty {
            document.selection = []
            needsDisplay = true
            return
        }
        window?.close()
    }

    override func keyDown(with event: NSEvent) {
        if document.tool == .select {
            if event.keyCode == 51, !document.selection.isEmpty {  // Delete
                document.deleteSelection()
                needsDisplay = true
                return
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                document.selectAll()
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Mouse

    /// Converts a mouse event to image-pixel coordinates (clamped to the image).
    private func imagePoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let iw = CGFloat(document.baseImage.width)
        let ih = CGFloat(document.baseImage.height)
        let s = min(bounds.width / iw, bounds.height / ih)
        let ox = (bounds.width - iw * s) / 2
        let oy = (bounds.height - ih * s) / 2
        return CGPoint(x: (p.x - ox) / s, y: (p.y - oy) / s).clamped(to: document.imageSize)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = imagePoint(for: event)
        switch document.tool {
        case .select:
            selectMouseDown(at: pt, event: event)
        case .text:
            document.pendingTextImagePoint = pt
            document.pendingTextPoint = convert(event.locationInWindow, from: nil)
        case .counter:
            document.addCounter(at: pt)
            needsDisplay = true
        case .pipette:
            document.pickColor(at: pt)
        case .eraser:
            document.erase(at: pt)
            needsDisplay = true
        case .pen:
            document.draftShape = Annotation(kind: .pen(points: [pt]),
                                             color: document.color, width: document.lineWidth)
            needsDisplay = true
        case .highlighter:
            document.draftShape = Annotation(kind: .highlight(points: [pt]),
                                             color: document.color, width: document.lineWidth)
            needsDisplay = true
        default:
            document.dragStart = pt
            document.draftShape = shapeDraft(from: pt, to: pt)
            needsDisplay = true
        }
    }

    // MARK: - Selection (Excalidraw-style)

    private enum Handle { case topLeft, topRight, bottomLeft, bottomRight }

    private var moveSnapshot: [UUID: Annotation]?
    private var moveStart: CGPoint?
    private var moveChanged = false
    private var resizeSnapshot: [UUID: Annotation]?
    private var resizeOrigBox: CGRect?
    private var resizeHandle: Handle?
    private var resizeChanged = false
    private var marqueeStart: CGPoint?
    private var marqueeAdditive = false

    /// Topmost selectable (transformable) annotation under an image-space point.
    private func topmostSelectable(at pt: CGPoint) -> Annotation? {
        for a in document.annotations.reversed() where a.isTransformable {
            if AnnotationRenderer.hitTest([a], at: pt, sketch: document.sketchStyle) != nil {
                return a
            }
        }
        return nil
    }

    /// Image point -> view point, for handle hit-testing in screen space.
    private func viewPoint(_ imagePt: CGPoint) -> CGPoint {
        let (s, o) = AnnotationRenderer.fit(imageSize: document.imageSize, in: bounds)
        return CGPoint(x: o.x + imagePt.x * s, y: o.y + imagePt.y * s)
    }

    /// Corner handle under the cursor, if any. Returns the selection box too.
    private func handleHit(at event: NSEvent) -> (box: CGRect, handle: Handle)? {
        guard let box = document.selectionBox() else { return nil }
        let pad: CGFloat = 7 / max(AnnotationRenderer.fit(imageSize: document.imageSize, in: bounds).scale, 0.01)
        let r = box.insetBy(dx: -pad, dy: -pad)
        let p = convert(event.locationInWindow, from: nil)
        let tol: CGFloat = 12
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, viewPoint(CGPoint(x: r.minX, y: r.minY))),
            (.topRight, viewPoint(CGPoint(x: r.maxX, y: r.minY))),
            (.bottomLeft, viewPoint(CGPoint(x: r.minX, y: r.maxY))),
            (.bottomRight, viewPoint(CGPoint(x: r.maxX, y: r.maxY))),
        ]
        for (h, c) in corners where hypot(p.x - c.x, p.y - c.y) <= tol {
            return (box, h)
        }
        return nil
    }

    private func selectMouseDown(at pt: CGPoint, event: NSEvent) {
        // Double-click a text annotation to edit it in place.
        if event.clickCount == 2 {
            if let hit = topmostSelectable(at: pt), case .text = hit.kind {
                document.startTextEdit(hit,
                                       viewPoint: convert(event.locationInWindow, from: nil),
                                       imagePoint: pt)
            }
            needsDisplay = true
            return
        }
        if let (box, handle) = handleHit(at: event) {
            resizeSnapshot = document.snapshotForTransform(ids: document.selection)
            resizeOrigBox = box
            resizeHandle = handle
            resizeChanged = false
            return
        }
        if let hit = topmostSelectable(at: pt) {
            if event.modifierFlags.contains(.shift) {
                var s = document.selection
                if s.contains(hit.id) { s.remove(hit.id) } else { s.insert(hit.id) }
                document.selection = s
            } else if !document.selection.contains(hit.id) {
                document.selection = [hit.id]
            }
            moveSnapshot = document.snapshotForTransform(ids: document.selection)
            moveStart = pt
            moveChanged = false
        } else {
            marqueeAdditive = event.modifierFlags.contains(.shift)
            if !marqueeAdditive { document.selection = [] }
            marqueeStart = pt
            document.marqueeRect = CGRect(origin: pt, size: .zero)
        }
        needsDisplay = true
    }

    private func selectMouseDragged(at pt: CGPoint) {
        if let snap = moveSnapshot, let start = moveStart {
            let delta = CGPoint(x: pt.x - start.x, y: pt.y - start.y)
            if delta.x != 0 || delta.y != 0 { moveChanged = true }
            document.applyMove(snapshot: snap, delta: delta)
            needsDisplay = true
        } else if let snap = resizeSnapshot,
                  let orig = resizeOrigBox, let handle = resizeHandle {
            let newBox = resizedBox(orig: orig, handle: handle, to: pt)
            if newBox != orig { resizeChanged = true }
            document.applyResize(snapshot: snap, from: orig, to: newBox)
            needsDisplay = true
        } else if let start = marqueeStart {
            document.marqueeRect = CGRect(from: start, to: pt)
            needsDisplay = true
        }
    }

    private func selectMouseUp() {
        if moveChanged, let snap = moveSnapshot {
            document.commitTransform(snapshot: snap)
        }
        if resizeChanged, let snap = resizeSnapshot {
            document.commitTransform(snapshot: snap)
        }
        if marqueeStart != nil, let m = document.marqueeRect,
           m.width > 4 || m.height > 4 {
            document.selectInRect(m, additive: marqueeAdditive)
        }
        moveSnapshot = nil
        moveStart = nil
        resizeSnapshot = nil
        resizeOrigBox = nil
        resizeHandle = nil
        marqueeStart = nil
        document.marqueeRect = nil
        needsDisplay = true
    }

    private func resizedBox(orig: CGRect, handle: Handle, to pt: CGPoint) -> CGRect {
        var x1 = orig.minX, y1 = orig.minY, x2 = orig.maxX, y2 = orig.maxY
        switch handle {
        case .topLeft: x1 = pt.x; y1 = pt.y
        case .topRight: x2 = pt.x; y1 = pt.y
        case .bottomLeft: x1 = pt.x; y2 = pt.y
        case .bottomRight: x2 = pt.x; y2 = pt.y
        }
        let minSize: CGFloat = 12
        if x2 - x1 < minSize {
            if handle == .topLeft || handle == .bottomLeft { x1 = x2 - minSize }
            else { x2 = x1 + minSize }
        }
        if y2 - y1 < minSize {
            if handle == .topLeft || handle == .topRight { y1 = y2 - minSize }
            else { y2 = y1 + minSize }
        }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = imagePoint(for: event)
        switch document.tool {
        case .select:
            selectMouseDragged(at: pt)
        case .pen, .highlighter:
            if var draft = document.draftShape {
                switch draft.kind {
                case .pen(var pts):
                    pts.append(pt)
                    draft.kind = .pen(points: pts)
                    document.draftShape = draft
                case .highlight(var pts):
                    pts.append(pt)
                    draft.kind = .highlight(points: pts)
                    document.draftShape = draft
                default:
                    break
                }
            }
            needsDisplay = true
        case .eraser:
            document.erase(at: pt)
            needsDisplay = true
        case .arrow, .line, .rect, .ellipse, .diamond:
            if let start = document.dragStart {
                document.draftShape = shapeDraft(from: start, to: pt)
                needsDisplay = true
            }
        case .blur:
            if let start = document.dragStart {
                document.draftBlurRect = CGRect(from: start, to: pt)
                needsDisplay = true
            }
        case .spotlight:
            if let start = document.dragStart {
                document.draftSpotlightRect = CGRect(from: start, to: pt)
                needsDisplay = true
            }
        case .crop:
            if let start = document.dragStart {
                document.draftCropRect = CGRect(from: start, to: pt)
                needsDisplay = true
            }
        case .text, .counter, .pipette, .select:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if document.tool == .select {
            selectMouseUp()
            return
        }
        defer {
            document.draftShape = nil
            document.draftBlurRect = nil
            document.draftSpotlightRect = nil
            document.dragStart = nil
            // draftCropRect is intentionally kept: the Apply button reads it.
            needsDisplay = true
        }
        switch document.tool {
        case .pen, .highlighter, .arrow, .line, .rect, .ellipse, .diamond:
            if let draft = document.draftShape, isSignificant(draft) {
                document.addAnnotation(draft)
            }
        case .blur:
            if let r = document.draftBlurRect, r.width >= 4, r.height >= 4,
               let patch = AnnotationRenderer.pixellatedPatch(of: document.baseImage, rect: r) {
                document.addAnnotation(Annotation(kind: .blur(rect: r, patch: patch),
                                                  color: document.color, width: 0))
            }
        case .spotlight:
            if let r = document.draftSpotlightRect, r.width >= 8, r.height >= 8 {
                document.addAnnotation(Annotation(kind: .spotlight(rect: r),
                                                  color: document.color, width: 0))
            }
        case .crop, .text, .counter, .eraser, .pipette:
            break
        }
    }

    // MARK: - Helpers

    private func shapeDraft(from: CGPoint, to: CGPoint) -> Annotation {
        let filled = document.fillStyle != .none
        let kind: Annotation.Kind
        switch document.tool {
        case .arrow: kind = .arrow(from: from, to: to)
        case .line: kind = .line(from: from, to: to)
        case .rect: kind = .rect(CGRect(from: from, to: to), filled: filled)
        case .ellipse: kind = .ellipse(CGRect(from: from, to: to), filled: filled)
        case .diamond: kind = .diamond(CGRect(from: from, to: to), filled: filled)
        default: kind = .line(from: from, to: to)
        }
        var a = Annotation(kind: kind, color: document.color, width: document.lineWidth)
        a.strokeStyle = document.strokeStyle
        a.fillStyle = document.fillStyle
        return a
    }

    private func isSignificant(_ a: Annotation) -> Bool {
        switch a.kind {
        case .arrow(let f, let t), .line(let f, let t):
            return hypot(t.x - f.x, t.y - f.y) > 4
        case .rect(let r, _), .ellipse(let r, _), .diamond(let r, _):
            return r.width > 4 && r.height > 4
        case .pen(let pts), .highlight(let pts):
            return pts.count > 1
        case .text, .counter, .blur, .spotlight:
            return true
        }
    }
}

// MARK: - SwiftUI bridge

struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var document: AnnotationDocument

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView()
        view.document = document
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        nsView.document = document
        nsView.needsDisplay = true
    }
}
