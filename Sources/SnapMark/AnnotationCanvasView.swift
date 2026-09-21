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
                                bounds: bounds)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc closes the editor (the text field consumes Esc while editing).
        window?.close()
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

    override func mouseDragged(with event: NSEvent) {
        let pt = imagePoint(for: event)
        switch document.tool {
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
        case .arrow, .line, .rect, .ellipse:
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
        case .text, .counter, .pipette:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            document.draftShape = nil
            document.draftBlurRect = nil
            document.draftSpotlightRect = nil
            document.dragStart = nil
            // draftCropRect is intentionally kept: the Apply button reads it.
            needsDisplay = true
        }
        switch document.tool {
        case .pen, .highlighter, .arrow, .line, .rect, .ellipse:
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
        let kind: Annotation.Kind
        switch document.tool {
        case .arrow: kind = .arrow(from: from, to: to)
        case .line: kind = .line(from: from, to: to)
        case .rect: kind = .rect(CGRect(from: from, to: to), filled: document.fillShapes)
        case .ellipse: kind = .ellipse(CGRect(from: from, to: to), filled: document.fillShapes)
        default: kind = .line(from: from, to: to)
        }
        return Annotation(kind: kind, color: document.color, width: document.lineWidth)
    }

    private func isSignificant(_ a: Annotation) -> Bool {
        switch a.kind {
        case .arrow(let f, let t), .line(let f, let t):
            return hypot(t.x - f.x, t.y - f.y) > 4
        case .rect(let r, _), .ellipse(let r, _):
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
