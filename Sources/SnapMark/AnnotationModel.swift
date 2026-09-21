import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case arrow, line, rect, ellipse, text, pen, highlighter
    case counter, eraser, pipette
    case blur, spotlight, crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .counter: return "Counter"
        case .eraser: return "Eraser"
        case .pipette: return "Color Picker"
        case .blur: return "Blur (redact)"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "ellipse"
        case .text: return "textformat"
        case .pen: return "pencil"
        case .highlighter: return "highlighter"
        case .counter: return "number.circle"
        case .eraser: return "eraser"
        case .pipette: return "eyedropper"
        case .blur: return "eye.slash"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }
}

// MARK: - Color

struct MarkColor: Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }

    static let palette: [MarkColor] = [
        MarkColor(r: 1, g: 0.23, b: 0.19),    // red
        MarkColor(r: 1, g: 0.58, b: 0),       // orange
        MarkColor(r: 1, g: 0.80, b: 0),       // yellow
        MarkColor(r: 0.20, g: 0.78, b: 0.35), // green
        MarkColor(r: 0, g: 0.48, b: 1),       // blue
        MarkColor(r: 0.69, g: 0.32, b: 1),    // purple
        MarkColor(r: 0.10, g: 0.10, b: 0.12), // near-black
        MarkColor(r: 1, g: 1, b: 1),          // white
    ]
}

// MARK: - Annotation

struct Annotation: Identifiable {
    enum Kind {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rect(CGRect, filled: Bool)
        case ellipse(CGRect, filled: Bool)
        case text(at: CGPoint, string: String)
        case pen(points: [CGPoint])
        case highlight(points: [CGPoint])
        case counter(at: CGPoint, number: Int)
        case blur(rect: CGRect, patch: CGImage)
        case spotlight(rect: CGRect)
    }

    let id = UUID()
    var kind: Kind
    var color: MarkColor
    var width: CGFloat      // line width, in image pixels
    var fontSize: CGFloat = 24
}

// MARK: - History

private struct CanvasState {
    var base: CGImage
    var annotations: [Annotation]
}

private enum HistoryEntry {
    case added(Annotation)
    case removed(Annotation, index: Int)
    case cropped(before: CanvasState, after: CanvasState)
}

// MARK: - Document

/// Holds the screenshot plus its annotations. All access happens on the main
/// thread (SwiftUI + AppKit are main-thread bound).
final class AnnotationDocument: ObservableObject {
    @Published var baseImage: CGImage
    @Published var annotations: [Annotation] = []
    @Published var tool: Tool = .arrow
    @Published var color: MarkColor = MarkColor.palette[0]
    @Published var customColor: MarkColor?
    @Published var lineWidth: CGFloat = 4
    @Published var fontSize: CGFloat = 24
    @Published var fillShapes = false
    @Published var sketchStyle = false
    @Published var pendingTextPoint: CGPoint?   // view coords, for the text field overlay
    @Published var draftCropRect: CGRect?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Capture-time metadata (date/time, user, frontmost app). Never changes.
    let metadata: ScreenshotMetadata

    // Transient drawing state, driven by the canvas view (it calls
    // needsDisplay directly, so these don't need to be published).
    var draftShape: Annotation?
    var draftBlurRect: CGRect?
    var draftSpotlightRect: CGRect?
    var dragStart: CGPoint?
    var pendingTextImagePoint: CGPoint?

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    var imageSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    init(image: NSImage, metadata: ScreenshotMetadata) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            fatalError("SnapMark: could not convert screenshot to CGImage")
        }
        self.baseImage = cg
        self.metadata = metadata
    }

    // MARK: Mutations

    func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
        undoStack.append(.added(annotation))
        redoStack.removeAll()
        syncHistoryFlags()
    }

    func erase(at point: CGPoint) {
        guard let hit = AnnotationRenderer.hitTest(annotations, at: point, sketch: sketchStyle),
              let idx = annotations.firstIndex(where: { $0.id == hit.id }) else { return }
        let removed = annotations.remove(at: idx)
        undoStack.append(.removed(removed, index: idx))
        redoStack.removeAll()
        syncHistoryFlags()
    }

    func addCounter(at point: CGPoint) {
        let n = (annotations.compactMap { a -> Int? in
            if case .counter(_, let number) = a.kind { return number }
            return nil
        }.max() ?? 0) + 1
        addAnnotation(Annotation(kind: .counter(at: point, number: n),
                                 color: color, width: lineWidth))
    }

    func pickColor(at point: CGPoint) {
        if let c = AnnotationRenderer.sampleColor(at: point, in: baseImage) {
            color = c
            customColor = c
        }
    }

    func applyCrop(_ rect: CGRect) {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard r.width >= 8, r.height >= 8, let cropped = baseImage.cropping(to: r) else { return }
        let before = CanvasState(base: baseImage, annotations: annotations)
        baseImage = cropped
        annotations = []
        let after = CanvasState(base: baseImage, annotations: annotations)
        undoStack.append(.cropped(before: before, after: after))
        redoStack.removeAll()
        draftCropRect = nil
        syncHistoryFlags()
    }

    func applyCropFromDraft() {
        guard let r = draftCropRect else { return }
        applyCrop(r)
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        switch entry {
        case .added(let a):
            annotations.removeAll { $0.id == a.id }
        case .removed(let a, let idx):
            annotations.insert(a, at: min(idx, annotations.count))
        case .cropped(let before, _):
            baseImage = before.base
            annotations = before.annotations
        }
        redoStack.append(entry)
        syncHistoryFlags()
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        switch entry {
        case .added(let a):
            annotations.append(a)
        case .removed(let a, _):
            annotations.removeAll { $0.id == a.id }
        case .cropped(_, let after):
            baseImage = after.base
            annotations = after.annotations
        }
        undoStack.append(entry)
        syncHistoryFlags()
    }

    private func syncHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Text

    func commitPendingText(_ string: String) {
        defer {
            pendingTextPoint = nil
            pendingTextImagePoint = nil
        }
        guard let at = pendingTextImagePoint,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addAnnotation(Annotation(kind: .text(at: at, string: string),
                                 color: color, width: lineWidth, fontSize: fontSize))
    }

    func cancelPendingText() {
        pendingTextPoint = nil
        pendingTextImagePoint = nil
    }

    // MARK: Export

    func renderedImage() -> NSImage {
        let size = imageSize
        let barH = urlBarHeight(for: size)
        let image = NSImage(size: CGSize(width: size.width, height: size.height + barH),
                            flipped: true)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            AnnotationRenderer.draw(base: baseImage,
                                    annotations: annotations,
                                    draftShape: nil,
                                    draftBlur: nil,
                                    draftSpotlight: nil,
                                    draftCrop: nil,
                                    sketch: sketchStyle,
                                    in: ctx,
                                    bounds: CGRect(origin: .zero, size: size))
            if barH > 0, let url = metadata.pageURL, !url.isEmpty {
                drawURLBar(url, in: ctx, imageSize: size, barHeight: barH)
            }
        }
        image.unlockFocus()
        return image
    }

    /// Height of the imprinted URL caption bar (0 when disabled or no URL).
    /// Toggle lives in Settings ("Imprint browser URL on screenshots").
    private func urlBarHeight(for size: CGSize) -> CGFloat {
        let enabled = UserDefaults.standard.object(forKey: "imprintPageURL") as? Bool ?? true
        guard enabled, let url = metadata.pageURL, !url.isEmpty else { return 0 }
        return max(48, size.width * 0.05)
    }

    /// Stamps the page URL onto a dark caption bar appended below the image.
    /// Called inside a flipped lockFocus context (origin top-left).
    private func drawURLBar(_ url: String, in ctx: CGContext,
                           imageSize size: CGSize, barHeight barH: CGFloat) {
        let barRect = CGRect(x: 0, y: size.height, width: size.width, height: barH)
        ctx.setFillColor(NSColor(white: 0.09, alpha: 1).cgColor)
        ctx.fill(barRect)
        // Hairline separator.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height, width: size.width, height: max(1, barH * 0.025)))

        let font = NSFont.systemFont(ofSize: barH * 0.36, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ]
        let padX = barH * 0.35
        var display = url
        let maxW = size.width - padX * 2
        while (display as NSString).size(withAttributes: attrs).width > maxW,
              display.count > 8 {
            display = String(display.dropLast(8)) + "…"
        }
        let textH = (display as NSString).size(withAttributes: attrs).height
        (display as NSString).draw(
            at: CGPoint(x: padX, y: size.height + (barH - textH) / 2),
            withAttributes: attrs
        )
    }

    /// PNG data with the capture metadata embedded as tEXt chunks
    /// (title, author, description, creation time) via ImageIO.
    private func pngData() -> Data? {
        let image = renderedImage()
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props = [kCGImagePropertyPNGDictionary as String: metadata.pngProperties] as CFDictionary
        CGImageDestinationAddImage(dest, cg, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func copyToClipboard() {
        guard let png = pngData() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "SnapMark \(fmt.string(from: metadata.capturedAt)).png"
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let png = self?.pngData() else { return }
            try? png.write(to: url)
        }
    }
}

// MARK: - Geometry helpers

extension CGRect {
    init(from p1: CGPoint, to p2: CGPoint) {
        self.init(x: min(p1.x, p2.x),
                  y: min(p1.y, p2.y),
                  width: abs(p2.x - p1.x),
                  height: abs(p2.y - p1.y))
    }
}

extension CGPoint {
    func clamped(to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(x, 0), size.width),
                y: min(max(y, 0), size.height))
    }
}
