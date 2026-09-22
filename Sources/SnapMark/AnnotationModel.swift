import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, diamond, text, pen, highlighter
    case counter, eraser, pipette
    case blur, spotlight, crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .diamond: return "Diamond"
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
        case .select: return "cursor.arrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "ellipse"
        case .diamond: return "diamond"
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

// MARK: - Stroke & fill styles (Excalidraw-inspired)

enum StrokeStyle: String, CaseIterable, Identifiable {
    case solid, dashed, dotted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }
}

enum FillStyle: String, CaseIterable, Identifiable {
    case none, solid, hachure, crossHatch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .solid: return "Solid"
        case .hachure: return "Hachure"
        case .crossHatch: return "Cross-hatch"
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
        case diamond(CGRect, filled: Bool)
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
    var strokeStyle: StrokeStyle = .solid
    var fillStyle: FillStyle = .none

    /// Blur and spotlight bake image content, so moving them would show the
    /// wrong pixels — they're erased, never selected.
    var isTransformable: Bool {
        switch kind {
        case .blur, .spotlight: return false
        default: return true
        }
    }

    /// Tight-ish box around the annotation, image-pixel space.
    func boundingBox(sketch: Bool) -> CGRect {
        switch kind {
        case .arrow(let f, let t), .line(let f, let t):
            let pad = width / 2 + 3
            return CGRect(from: f, to: t).insetBy(dx: -pad, dy: -pad)
        case .rect(let r, _), .ellipse(let r, _), .diamond(let r, _):
            return r.insetBy(dx: -3, dy: -3)
        case .text:
            return AnnotationRenderer.textBox(for: self, sketch: sketch)
        case .pen(let pts), .highlight(let pts):
            guard let first = pts.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for p in pts.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
            let pad = width / 2 + 2
            return box.insetBy(dx: -pad, dy: -pad)
        case .counter(let at, _):
            return CGRect(x: at.x - 17, y: at.y - 17, width: 34, height: 34)
        case .blur(let r, _), .spotlight(let r):
            return r
        }
    }

    /// Returns a copy translated by `delta`.
    func moved(by delta: CGPoint) -> Annotation {
        var a = self
        switch kind {
        case .arrow(let f, let t):
            a.kind = .arrow(from: f + delta, to: t + delta)
        case .line(let f, let t):
            a.kind = .line(from: f + delta, to: t + delta)
        case .rect(let r, let filled):
            a.kind = .rect(r.offsetBy(dx: delta.x, dy: delta.y), filled: filled)
        case .ellipse(let r, let filled):
            a.kind = .ellipse(r.offsetBy(dx: delta.x, dy: delta.y), filled: filled)
        case .diamond(let r, let filled):
            a.kind = .diamond(r.offsetBy(dx: delta.x, dy: delta.y), filled: filled)
        case .text(let at, let s):
            a.kind = .text(at: at + delta, string: s)
        case .pen(let pts):
            a.kind = .pen(points: pts.map { $0 + delta })
        case .highlight(let pts):
            a.kind = .highlight(points: pts.map { $0 + delta })
        case .counter(let at, let n):
            a.kind = .counter(at: at + delta, number: n)
        case .blur(let r, let patch):
            a.kind = .blur(rect: r.offsetBy(dx: delta.x, dy: delta.y), patch: patch)
        case .spotlight(let r):
            a.kind = .spotlight(rect: r.offsetBy(dx: delta.x, dy: delta.y))
        }
        return a
    }

    /// Returns a copy remapped from `oldBox` to `newBox` (resize). Degenerate
    /// source boxes fall back to a pure translation.
    func resized(from oldBox: CGRect, to newBox: CGRect) -> Annotation {
        let sx: CGFloat = oldBox.width > 0.5 ? newBox.width / oldBox.width : 1
        let sy: CGFloat = oldBox.height > 0.5 ? newBox.height / oldBox.height : 1
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: newBox.minX + (p.x - oldBox.minX) * sx,
                    y: newBox.minY + (p.y - oldBox.minY) * sy)
        }
        func mapRect(_ r: CGRect) -> CGRect {
            let p1 = map(r.origin)
            let p2 = map(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(from: p1, to: p2)
        }
        var a = self
        switch kind {
        case .arrow(let f, let t):
            a.kind = .arrow(from: map(f), to: map(t))
        case .line(let f, let t):
            a.kind = .line(from: map(f), to: map(t))
        case .rect(let r, let filled):
            a.kind = .rect(mapRect(r), filled: filled)
        case .ellipse(let r, let filled):
            a.kind = .ellipse(mapRect(r), filled: filled)
        case .diamond(let r, let filled):
            a.kind = .diamond(mapRect(r), filled: filled)
        case .text(let at, let s):
            a.kind = .text(at: map(at), string: s)
            a.fontSize = min(400, max(8, fontSize * sx))
        case .pen(let pts):
            a.kind = .pen(points: pts.map(map))
        case .highlight(let pts):
            a.kind = .highlight(points: pts.map(map))
        case .counter(let at, let n):
            a.kind = .counter(at: map(at), number: n)
        case .blur(let r, let patch):
            a.kind = .blur(rect: mapRect(r), patch: patch)
        case .spotlight(let r):
            a.kind = .spotlight(rect: mapRect(r))
        }
        return a
    }
}

// MARK: - History

private struct CanvasState {
    var base: CGImage
    var annotations: [Annotation]
}

private enum HistoryEntry {
    case added(Annotation)
    case addedMany([Annotation])
    case removed(Annotation, index: Int)
    case removedMany([(annotation: Annotation, index: Int)])
    case transformed([(id: UUID, before: Annotation, after: Annotation)])
    case cropped(before: CanvasState, after: CanvasState)
}

// MARK: - Document

/// Holds the screenshot plus its annotations. All access happens on the main
/// thread (SwiftUI + AppKit are main-thread bound).
final class AnnotationDocument: ObservableObject {
    @Published var baseImage: CGImage
    @Published var annotations: [Annotation] = []
    @Published var tool: Tool = .select
    @Published var color: MarkColor = MarkColor.palette[0]
    @Published var customColor: MarkColor?
    @Published var lineWidth: CGFloat = 4
    @Published var fontSize: CGFloat = 24
    @Published var strokeStyle: StrokeStyle = .solid
    @Published var fillStyle: FillStyle = .none
    @Published var sketchStyle = true
    @Published var selection: Set<UUID> = []
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
    var marqueeRect: CGRect?          // image-pixel space, select tool only
    var textEditTarget: UUID?         // when set, the text overlay edits this annotation
    var textEditInitial = ""

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
        selection.remove(removed.id)
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
        selection.removeAll()
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
            selection.remove(a.id)
        case .addedMany(let many):
            let ids = Set(many.map(\.id))
            annotations.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
        case .removed(let a, let idx):
            annotations.insert(a, at: min(idx, annotations.count))
        case .removedMany(let pairs):
            for pair in pairs.sorted(by: { $0.index < $1.index }) {
                annotations.insert(pair.annotation, at: min(pair.index, annotations.count))
            }
        case .transformed(let pairs):
            for (id, before, _) in pairs {
                if let idx = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[idx] = before
                }
            }
        case .cropped(let before, _):
            baseImage = before.base
            annotations = before.annotations
            selection.removeAll()
        }
        redoStack.append(entry)
        syncHistoryFlags()
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        switch entry {
        case .added(let a):
            annotations.append(a)
        case .addedMany(let many):
            annotations.append(contentsOf: many)
        case .removed(let a, _):
            annotations.removeAll { $0.id == a.id }
            selection.remove(a.id)
        case .removedMany(let pairs):
            let ids = Set(pairs.map(\.annotation.id))
            annotations.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
        case .transformed(let pairs):
            for (id, _, after) in pairs {
                if let idx = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[idx] = after
                }
            }
        case .cropped(_, let after):
            baseImage = after.base
            annotations = after.annotations
            selection.removeAll()
        }
        undoStack.append(entry)
        syncHistoryFlags()
    }

    private func syncHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Selection & transforms (Excalidraw-style)

    /// Union box of the current selection, image-pixel space.
    func selectionBox() -> CGRect? {
        let boxes = annotations
            .filter { selection.contains($0.id) }
            .map { $0.boundingBox(sketch: sketchStyle) }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    func selectAll() {
        selection = Set(annotations.filter(\.isTransformable).map(\.id))
    }

    func selectInRect(_ rect: CGRect, additive: Bool) {
        let sketch = sketchStyle
        let ids = Set(annotations
            .filter { $0.isTransformable && $0.boundingBox(sketch: sketch).intersects(rect) }
            .map(\.id))
        selection = additive ? selection.union(ids) : ids
    }

    func deleteSelection() {
        let targets = selection
        guard !targets.isEmpty else { return }
        var removed: [(annotation: Annotation, index: Int)] = []
        for (i, a) in annotations.enumerated() where targets.contains(a.id) {
            removed.append((annotation: a, index: i))
        }
        annotations.removeAll { targets.contains($0.id) }
        selection.removeAll()
        undoStack.append(.removedMany(removed))
        redoStack.removeAll()
        syncHistoryFlags()
    }

    /// Snapshot the given annotations before a drag; the canvas maps every
    /// drag update from this snapshot so there's no error accumulation.
    func snapshotForTransform(ids: Set<UUID>) -> [UUID: Annotation] {
        var snap: [UUID: Annotation] = [:]
        for a in annotations where ids.contains(a.id) { snap[a.id] = a }
        return snap
    }

    func applyMove(snapshot: [UUID: Annotation], delta: CGPoint) {
        for (id, before) in snapshot {
            if let idx = annotations.firstIndex(where: { $0.id == id }) {
                annotations[idx] = before.moved(by: delta)
            }
        }
    }

    func applyResize(snapshot: [UUID: Annotation], from oldBox: CGRect, to newBox: CGRect) {
        for (id, before) in snapshot {
            if let idx = annotations.firstIndex(where: { $0.id == id }) {
                annotations[idx] = before.resized(from: oldBox, to: newBox)
            }
        }
    }

    /// Pushes a single undo entry for a finished move/resize drag.
    func commitTransform(snapshot: [UUID: Annotation]) {
        var pairs: [(id: UUID, before: Annotation, after: Annotation)] = []
        for (id, before) in snapshot {
            if let after = annotations.first(where: { $0.id == id }) {
                pairs.append((id: id, before: before, after: after))
            }
        }
        guard !pairs.isEmpty else { return }
        undoStack.append(.transformed(pairs))
        redoStack.removeAll()
        syncHistoryFlags()
    }

    func updateText(id: UUID, string: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        var a = annotations[idx]
        guard case .text(let at, _) = a.kind else { return }
        let before = a
        a.kind = .text(at: at, string: string)
        annotations[idx] = a
        undoStack.append(.transformed([(id: id, before: before, after: a)]))
        redoStack.removeAll()
        syncHistoryFlags()
    }

    func startTextEdit(_ a: Annotation, viewPoint: CGPoint, imagePoint: CGPoint) {
        guard case .text(_, let s) = a.kind else { return }
        textEditTarget = a.id
        textEditInitial = s
        pendingTextImagePoint = imagePoint
        pendingTextPoint = viewPoint
    }

    // MARK: Text

    func commitPendingText(_ string: String) {
        let target = textEditTarget
        defer {
            pendingTextPoint = nil
            pendingTextImagePoint = nil
            textEditTarget = nil
            textEditInitial = ""
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = target {
            updateText(id: id, string: string)
            return
        }
        guard let at = pendingTextImagePoint else { return }
        addAnnotation(Annotation(kind: .text(at: at, string: string),
                                 color: color, width: lineWidth, fontSize: fontSize))
    }

    func cancelPendingText() {
        pendingTextPoint = nil
        pendingTextImagePoint = nil
        textEditTarget = nil
        textEditInitial = ""
    }

    // MARK: - On-device AI

    /// CGImage of the base image for Vision requests.
    func cgImageForAI() -> CGImage? { baseImage }

    /// Adds blur annotations over the given rects (image-point space, top-left
    /// origin) as a single undo step. Used by face / PII auto-redaction.
    func redact(rects: [CGRect]) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        var made: [Annotation] = []
        for rect in rects {
            let r = rect.intersection(bounds)
            guard r.width >= 4, r.height >= 4,
                  let patch = AnnotationRenderer.pixellatedPatch(of: baseImage, rect: r) else { continue }
            made.append(Annotation(kind: .blur(rect: r, patch: patch),
                                   color: color, width: 0))
        }
        guard !made.isEmpty else { return }
        annotations.append(contentsOf: made)
        undoStack.append(.addedMany(made))
        redoStack.removeAll()
        syncHistoryFlags()
    }

    // MARK: Export

    func renderedImage() -> NSImage {
        let size = imageSize
        let image = NSImage(size: size, flipped: true)
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
            // Burn the configured metadata stamp onto saved/copied/pinned output.
            StampRenderer.drawStamp(StampSettings.load(), metadata: metadata,
                                    in: ctx, imageSize: size)
        }
        image.unlockFocus()
        return image
    }

    /// True when the stamp is on, its Page URL field is on, the capture came
    /// from a supported browser, but no URL could be read — almost always a
    /// denied Automation permission. The editor surfaces this as a warning.
    var urlCaptureWarningNeeded: Bool {
        let settings = StampSettings.load()
        return settings.enabled
            && settings.isFieldEnabled(.pageURL)
            && metadata.urlCaptureAttempted
            && (metadata.pageURL?.isEmpty ?? true)
    }

    /// e.g. "SnapMark_example.com_2026-09-21_08.44.20.png".
    func suggestedFileName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        return "SnapMark_\(metadata.fileSourceName)_\(fmt.string(from: metadata.capturedAt)).png"
    }

    /// PNG data with the capture metadata embedded as tEXt chunks
    /// (title, author, description, creation time) via ImageIO.
    /// Internal so the editor can hand it to the Drive uploader.
    func pngData() -> Data? {
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
        saveToFile(nameField: suggestedFileName())
    }

    func saveToFile(nameField: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = nameField
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

    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}
