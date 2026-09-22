import AppKit
import CoreGraphics
import CoreImage

/// All annotation drawing goes through here, in one coordinate space:
/// image pixels, origin top-left, y down (matches a flipped AppKit context).
/// The same routine paints the on-screen canvas and the exported PNG.
enum AnnotationRenderer {

    static func draw(base: CGImage,
                     annotations: [Annotation],
                     draftShape: Annotation?,
                     draftBlur: CGRect?,
                     draftSpotlight: CGRect?,
                     draftCrop: CGRect?,
                     sketch: Bool,
                     in ctx: CGContext,
                     bounds: CGRect,
                     selection: Set<UUID> = [],
                     marquee: CGRect? = nil) {
        let iw = CGFloat(base.width), ih = CGFloat(base.height)
        guard iw > 0, ih > 0, bounds.width > 0, bounds.height > 0 else { return }

        // Aspect-fit the image into bounds.
        let (s, origin) = fit(imageSize: CGSize(width: iw, height: ih), in: bounds)
        let ox = origin.x, oy = origin.y
        let imageSize = CGSize(width: iw, height: ih)

        ctx.saveGState()
        ctx.draw(base, in: CGRect(x: ox, y: oy, width: iw * s, height: ih * s))
        // From here on we work in image-pixel space; strokes scale with zoom.
        ctx.concatenate(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ox, ty: oy))

        for a in annotations { drawAnnotation(a, imageSize: imageSize, sketch: sketch, in: ctx) }
        if let d = draftShape { drawAnnotation(d, imageSize: imageSize, sketch: sketch, in: ctx) }

        if let r = draftBlur {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)
        }

        if let r = draftSpotlight {
            dimOutside(r, imageSize: imageSize, in: ctx)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)
        }

        if let r = draftCrop {
            dimOutside(r, imageSize: imageSize, in: ctx)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)
        }

        if let m = marquee {
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
            ctx.fill(m)
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5 / s)
            ctx.stroke(m)
        }

        if !selection.isEmpty {
            drawSelection(selection, annotations: annotations, scale: s, sketch: sketch, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Aspect-fit transform: image-pixel point * scale + origin = view point.
    static func fit(imageSize: CGSize, in bounds: CGRect) -> (scale: CGFloat, origin: CGPoint) {
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let ox = bounds.minX + (bounds.width - imageSize.width * s) / 2
        let oy = bounds.minY + (bounds.height - imageSize.height * s) / 2
        return (s, CGPoint(x: ox, y: oy))
    }

    /// Excalidraw-style selection: dashed blue outline plus corner handles.
    private static func drawSelection(_ ids: Set<UUID>, annotations: [Annotation],
                                      scale s: CGFloat, sketch: Bool, in ctx: CGContext) {
        let boxes = annotations
            .filter { ids.contains($0.id) }
            .map { $0.boundingBox(sketch: sketch) }
        guard let first = boxes.first else { return }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let pad: CGFloat = 7 / s
        let r = union.insetBy(dx: -pad, dy: -pad)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5 / s)
        ctx.setLineDash(phase: 0, lengths: [7 / s, 5 / s])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        let h = 11 / s
        let corners = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ]
        for c in corners {
            let hr = CGRect(x: c.x - h / 2, y: c.y - h / 2, width: h, height: h)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(hr)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5 / s)
            ctx.stroke(hr)
        }
        ctx.restoreGState()
    }

    private static func dimOutside(_ r: CGRect, imageSize: CGSize, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: imageSize)
        let path = CGMutablePath()
        path.addRect(full)
        path.addRect(r)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
    }

    // MARK: - Annotations

    private static func drawAnnotation(_ a: Annotation, imageSize: CGSize, sketch: Bool, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(a.width)
        let seed = seed(for: a.id)
        switch a.kind {
        case .arrow(let from, let to):
            ctx.setStrokeColor(a.color.cgColor)
            applyDash(a.strokeStyle, in: ctx)
            if sketch {
                sketchyLine(from: from, to: to, width: a.width, seed: seed, in: ctx)
                sketchyArrowHead(tip: to, from: from, size: max(12, a.width * 3.5),
                                 width: a.width, seed: seed ^ 0xABCDEF, in: ctx)
            } else {
                strokeLine(from: from, to: to, in: ctx)
                drawArrowHead(tip: to, from: from, size: max(12, a.width * 3.5), in: ctx)
            }
        case .line(let from, let to):
            ctx.setStrokeColor(a.color.cgColor)
            applyDash(a.strokeStyle, in: ctx)
            if sketch {
                sketchyLine(from: from, to: to, width: a.width, seed: seed, in: ctx)
            } else {
                strokeLine(from: from, to: to, in: ctx)
            }
        case .rect(let r, let filled):
            if filled {
                fillStyled(path: CGPath(rect: r, transform: nil), bounds: r,
                           style: a.fillStyle, color: a.color, seed: seed, sketch: sketch, in: ctx)
            }
            ctx.setStrokeColor(a.color.cgColor)
            applyDash(a.strokeStyle, in: ctx)
            if sketch {
                sketchyRect(r, width: a.width, seed: seed, in: ctx)
            } else {
                ctx.stroke(r)
            }
        case .ellipse(let r, let filled):
            if filled {
                let path = CGMutablePath()
                path.addEllipse(in: r)
                fillStyled(path: path, bounds: r,
                           style: a.fillStyle, color: a.color, seed: seed, sketch: sketch, in: ctx)
            }
            ctx.setStrokeColor(a.color.cgColor)
            applyDash(a.strokeStyle, in: ctx)
            if sketch {
                sketchyEllipse(r, width: a.width, seed: seed, in: ctx)
            } else {
                ctx.strokeEllipse(in: r)
            }
        case .diamond(let r, let filled):
            let path = diamondPath(in: r)
            if filled {
                fillStyled(path: path, bounds: r,
                           style: a.fillStyle, color: a.color, seed: seed, sketch: sketch, in: ctx)
            }
            ctx.setStrokeColor(a.color.cgColor)
            applyDash(a.strokeStyle, in: ctx)
            if sketch {
                sketchyDiamond(r, width: a.width, seed: seed, in: ctx)
            } else {
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .text(let at, let string):
            drawText(at: at, string: string, annotation: a, sketch: sketch, in: ctx)
        case .pen(let points):
            ctx.setStrokeColor(a.color.cgColor)
            strokePolyline(points, in: ctx)
        case .highlight(let points):
            ctx.setStrokeColor(a.color.nsColor.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(a.width * 3)
            strokePolyline(points, in: ctx)
        case .counter(let at, let number):
            drawCounter(at: at, number: number, color: a.color, in: ctx)
        case .blur(let r, let patch):
            ctx.draw(patch, in: r)
        case .spotlight(let r):
            dimOutside(r, imageSize: imageSize, in: ctx)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    // MARK: - Hand-drawn (sketch) style

    /// Deterministic seed per annotation so the wobble never shimmers between redraws.
    private static func seed(for id: UUID) -> UInt64 {
        var h: UInt64 = 14695981039346656037 // FNV-1a offset basis
        for b in id.uuidString.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return h
    }

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func subdivided(from: CGPoint, to: CGPoint, step: CGFloat = 9) -> [CGPoint] {
        let dist = hypot(to.x - from.x, to.y - from.y)
        let n = max(1, Int(dist / step))
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: from.x + (to.x - from.x) * t,
                           y: from.y + (to.y - from.y) * t)
        }
    }

    /// Draws a polyline twice with slight deterministic wobble, like pen strokes.
    private static func sketchyPolyline(_ points: [CGPoint], width: CGFloat,
                                        seed: UInt64, closed: Bool = false, in ctx: CGContext) {
        guard points.count > 1 else { return }
        for pass in 0..<2 {
            var rng = SeededRNG(seed: seed ^ (UInt64(pass) &* 0x9E3779B97F4A7C15))
            let wobble = max(1.2, width * 0.35)
            var out: [CGPoint] = []
            out.reserveCapacity(points.count)
            for (i, p) in points.enumerated() {
                let isAnchor = !closed && (i == 0 || i == points.count - 1)
                if isAnchor {
                    out.append(p)
                } else {
                    let prev = points[(i + points.count - 1) % points.count]
                    let next = points[(i + 1) % points.count]
                    let dx = next.x - prev.x, dy = next.y - prev.y
                    let len = hypot(dx, dy)
                    var ox: CGFloat = 0, oy: CGFloat = 0
                    if len > 0.001 {
                        let off = CGFloat.random(in: -wobble...wobble, using: &rng)
                        ox = -dy / len * off
                        oy = dx / len * off
                    }
                    out.append(CGPoint(x: p.x + ox, y: p.y + oy))
                }
            }
            ctx.beginPath()
            ctx.move(to: out[0])
            for p in out.dropFirst() { ctx.addLine(to: p) }
            if closed { ctx.closePath() }
            ctx.strokePath()
        }
    }

    private static func sketchyLine(from: CGPoint, to: CGPoint, width: CGFloat,
                                    seed: UInt64, in ctx: CGContext) {
        sketchyPolyline(subdivided(from: from, to: to), width: width, seed: seed, in: ctx)
    }

    private static func sketchyArrowHead(tip: CGPoint, from: CGPoint, size: CGFloat,
                                         width: CGFloat, seed: UInt64, in ctx: CGContext) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread: CGFloat = 0.5
        for (idx, sign) in ([-1.0, 1.0] as [CGFloat]).enumerated() {
            let a = angle + .pi + sign * spread
            let p = CGPoint(x: tip.x + cos(a) * size, y: tip.y + sin(a) * size)
            sketchyPolyline(subdivided(from: tip, to: p, step: 6),
                            width: width, seed: seed ^ UInt64(idx + 1), in: ctx)
        }
    }

    private static func sketchyRect(_ r: CGRect, width: CGFloat, seed: UInt64, in ctx: CGContext) {
        let corners = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
        ]
        var pts: [CGPoint] = []
        for i in 0..<4 {
            pts.append(contentsOf: subdivided(from: corners[i], to: corners[(i + 1) % 4]).dropLast())
        }
        sketchyPolyline(pts, width: width, seed: seed, closed: true, in: ctx)
    }

    private static func sketchyEllipse(_ r: CGRect, width: CGFloat, seed: UInt64, in ctx: CGContext) {
        let n = 56
        let pts = (0..<n).map { i -> CGPoint in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: r.midX + cos(a) * r.width / 2,
                           y: r.midY + sin(a) * r.height / 2)
        }
        sketchyPolyline(pts, width: width, seed: seed, closed: true, in: ctx)
    }

    private static func diamondCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private static func diamondPath(in r: CGRect) -> CGPath {
        let corners = diamondCorners(r)
        let path = CGMutablePath()
        path.move(to: corners[0])
        for c in corners.dropFirst() { path.addLine(to: c) }
        path.closeSubpath()
        return path
    }

    private static func sketchyDiamond(_ r: CGRect, width: CGFloat, seed: UInt64, in ctx: CGContext) {
        let corners = diamondCorners(r)
        var pts: [CGPoint] = []
        for i in 0..<4 {
            pts.append(contentsOf: subdivided(from: corners[i], to: corners[(i + 1) % 4]).dropLast())
        }
        sketchyPolyline(pts, width: width, seed: seed, closed: true, in: ctx)
    }

    // MARK: - Stroke & fill styles

    private static func applyDash(_ style: StrokeStyle, in ctx: CGContext) {
        switch style {
        case .solid:
            ctx.setLineDash(phase: 0, lengths: [])
        case .dashed:
            ctx.setLineDash(phase: 0, lengths: [16, 10])
        case .dotted:
            // Round caps turn the near-zero dash into dots.
            ctx.setLineDash(phase: 0, lengths: [0.01, 9])
        }
    }

    /// Solid fill, or Excalidraw-style hachure / cross-hatch clipped to the shape.
    private static func fillStyled(path: CGPath, bounds: CGRect, style: FillStyle,
                                   color: MarkColor, seed: UInt64, sketch: Bool, in ctx: CGContext) {
        switch style {
        case .none:
            break
        case .solid:
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        case .hachure, .crossHatch:
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            hatchLines(in: bounds, direction: 1, color: color,
                       seed: seed, sketch: sketch, in: ctx)
            if style == .crossHatch {
                hatchLines(in: bounds, direction: -1, color: color,
                           seed: seed ^ 0x77AA, sketch: sketch, in: ctx)
            }
            ctx.restoreGState()
        }
    }

    private static func hatchLines(in bounds: CGRect, direction dir: CGFloat, color: MarkColor,
                                   seed: UInt64, sketch: Bool, in ctx: CGContext) {
        ctx.setStrokeColor(color.nsColor.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2)
        let diag = hypot(bounds.width, bounds.height) + 20
        // 45° lines; `dir` flips the slope for cross-hatch.
        let dx = 1 / sqrt(2), dy = dir / sqrt(2)
        // Step along the perpendicular (-dy, dx).
        let px = -dy, py = dx
        let spacing: CGFloat = 10
        var offset = -diag
        var lineIndex: UInt64 = 0
        while offset < diag {
            let cx = bounds.midX + px * offset
            let cy = bounds.midY + py * offset
            let p1 = CGPoint(x: cx - dx * diag, y: cy - dy * diag)
            let p2 = CGPoint(x: cx + dx * diag, y: cy + dy * diag)
            if sketch {
                sketchyPolyline(subdivided(from: p1, to: p2, step: 14), width: 2,
                                seed: seed ^ (lineIndex &* 0x9E3779B9), in: ctx)
            } else {
                strokeLine(from: p1, to: p2, in: ctx)
            }
            offset += spacing
            lineIndex += 1
        }
    }

    // MARK: - Text

    private static func textAttributes(for a: Annotation, sketch: Bool) -> [NSAttributedString.Key: Any] {
        var font = NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)
        if sketch, let marker = NSFont(name: "Marker Felt", size: a.fontSize * 1.18) {
            font = marker // falls back to system font if unavailable
        }
        return [.font: font, .foregroundColor: a.color.nsColor]
    }

    private static func drawText(at: CGPoint, string: String, annotation a: Annotation,
                                 sketch: Bool, in ctx: CGContext) {
        let str = NSAttributedString(string: string, attributes: textAttributes(for: a, sketch: sketch))
        if sketch {
            // A whisper of rotation sells the handwritten feel.
            var rng = SeededRNG(seed: seed(for: a.id) ^ 0x1234)
            let rotation = CGFloat.random(in: -0.04...0.04, using: &rng)
            ctx.saveGState()
            ctx.translateBy(x: at.x, y: at.y)
            ctx.rotate(by: rotation)
            str.draw(at: .zero)
            ctx.restoreGState()
        } else {
            str.draw(at: at)
        }
    }

    /// Bounding box of a text annotation, used for selection and hit testing.
    static func textBox(for a: Annotation, sketch: Bool) -> CGRect {
        guard case .text(let at, let string) = a.kind else { return .zero }
        let sz = (string as NSString).size(withAttributes: textAttributes(for: a, sketch: sketch))
        return CGRect(origin: at, size: sz)
    }

    // MARK: - Plain strokes

    private static func drawCounter(at: CGPoint, number: Int, color: MarkColor, in ctx: CGContext) {
        let radius: CGFloat = 14
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: at.x - radius, y: at.y - radius,
                                   width: radius * 2, height: radius * 2))
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.white
        ]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: at.x - sz.width / 2, y: at.y - sz.height / 2),
                  withAttributes: attrs)
    }

    private static func strokeLine(from: CGPoint, to: CGPoint, in ctx: CGContext) {
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    private static func strokePolyline(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        if points.count == 1 {
            // A click without a drag still leaves a dot.
            ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y + 0.1))
        }
        ctx.strokePath()
    }

    private static func drawArrowHead(tip: CGPoint, from: CGPoint, size: CGFloat, in ctx: CGContext) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread: CGFloat = 0.5 // ~29°
        for sign: CGFloat in [-1, 1] {
            let a = angle + .pi + sign * spread
            let p = CGPoint(x: tip.x + cos(a) * size, y: tip.y + sin(a) * size)
            strokeLine(from: tip, to: p, in: ctx)
        }
    }

    // MARK: - Redaction

    /// Pixellates a region of the image. Coordinates are image pixels,
    /// origin top-left (matches `CGImage.cropping(to:)`).
    static func pixellatedPatch(of image: CGImage, rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 4, r.height >= 4, let cropped = image.cropping(to: r) else { return nil }
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
        filter.setValue(max(6, min(r.width, r.height) / 10), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        let ciContext = CIContext(options: nil)
        return ciContext.createCGImage(output, from: CGRect(origin: .zero, size: r.size))
    }

    // MARK: - Color sampling

    /// Reads a single pixel from the image (origin top-left).
    static func sampleColor(at point: CGPoint, in image: CGImage) -> MarkColor? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        guard let px = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        let a = CGFloat(bytes[3]) / 255
        guard a > 0.01 else { return nil }
        let r = min(max(CGFloat(bytes[0]) / 255 / a, 0), 1)
        let g = min(max(CGFloat(bytes[1]) / 255 / a, 0), 1)
        let b = min(max(CGFloat(bytes[2]) / 255 / a, 0), 1)
        return MarkColor(r: Double(r), g: Double(g), b: Double(b))
    }

    // MARK: - Hit testing (for the eraser)

    /// Topmost annotation under `point` (image-pixel coords), if any.
    static func hitTest(_ annotations: [Annotation], at point: CGPoint,
                        tolerance: CGFloat = 10, sketch: Bool = false) -> Annotation? {
        for a in annotations.reversed() {
            if hits(a, at: point, tolerance: tolerance, sketch: sketch) { return a }
        }
        return nil
    }

    private static func hits(_ a: Annotation, at p: CGPoint, tolerance t: CGFloat, sketch: Bool) -> Bool {
        switch a.kind {
        case .arrow(let f, let to), .line(let f, let to):
            return distanceToSegment(p, f, to) <= max(t, a.width / 2 + 2)
        case .rect(let r, let filled):
            return filled ? r.insetBy(dx: -t / 2, dy: -t / 2).contains(p) : nearRectOutline(p, r, t)
        case .ellipse(let r, let filled):
            return filled ? r.insetBy(dx: -t / 2, dy: -t / 2).contains(p) : nearEllipseOutline(p, r, t)
        case .diamond(let r, let filled):
            let corners = diamondCorners(r)
            if filled { return pointInPolygon(p, corners) }
            return nearPolygonOutline(p, corners, t)
        case .text(let at, let string):
            let sz = (string as NSString).size(withAttributes: textAttributes(for: a, sketch: sketch))
            return CGRect(origin: at, size: sz).insetBy(dx: -t / 2, dy: -t / 2).contains(p)
        case .pen(let pts), .highlight(let pts):
            let tol = t + a.width / 2
            for (p1, p2) in zip(pts, pts.dropFirst()) {
                if distanceToSegment(p, p1, p2) <= tol { return true }
            }
            return false
        case .counter(let at, _):
            return hypot(p.x - at.x, p.y - at.y) <= 14 + t / 2
        case .blur(let r, _), .spotlight(let r):
            return r.contains(p)
        }
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func nearRectOutline(_ p: CGPoint, _ r: CGRect, _ t: CGFloat) -> Bool {
        let outer = r.insetBy(dx: -t / 2, dy: -t / 2)
        let inner = r.insetBy(dx: t / 2, dy: t / 2)
        return outer.contains(p) && !inner.contains(p)
    }

    private static func nearEllipseOutline(_ p: CGPoint, _ r: CGRect, _ t: CGFloat) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let rx = r.width / 2, ry = r.height / 2
        let d = sqrt(pow((p.x - r.midX) / rx, 2) + pow((p.y - r.midY) / ry, 2))
        return abs(d - 1) * min(rx, ry) <= t / 2
    }

    private static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        // Ray casting.
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func nearPolygonOutline(_ p: CGPoint, _ poly: [CGPoint], _ t: CGFloat) -> Bool {
        for i in 0..<poly.count {
            if distanceToSegment(p, poly[i], poly[(i + 1) % poly.count]) <= t / 2 + 1 {
                return true
            }
        }
        return false
    }
}
