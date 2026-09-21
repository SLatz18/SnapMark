import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

/// On-device AI powered by Apple's Vision and Natural Language frameworks.
/// Everything runs locally: no network, no API keys, no downloads.
/// Available on every Mac that runs SnapMark (macOS 13+).
enum LocalAI {

    // MARK: - OCR

    struct TextLine {
        var text: String
        /// Pixel rect in image coordinates, top-left origin.
        var box: CGRect
    }

    /// Recognizes text lines in the image, accurate mode.
    static func recognizeText(in cgImage: CGImage) async throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await perform(request, on: cgImage)
            .compactMap { $0 as? VNRecognizedTextObservation }
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        return observations.compactMap { obs in
            guard let candidate = try? obs.topCandidates(1).first else { return nil }
            return TextLine(text: candidate.string,
                            box: denormalize(obs.boundingBox, width: w, height: h))
        }
    }

    static func plainText(in cgImage: CGImage) async throws -> String {
        try await recognizeText(in: cgImage).map(\.text).joined(separator: "\n")
    }

    // MARK: - Barcodes

    struct Barcode {
        var payload: String?
        /// Pixel rect in image coordinates, top-left origin.
        var box: CGRect
    }

    static func detectBarcodes(in cgImage: CGImage) async throws -> [Barcode] {
        let request = VNDetectBarcodesRequest()
        let observations = try await perform(request, on: cgImage)
            .compactMap { $0 as? VNBarcodeObservation }
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        return observations.map {
            Barcode(payload: $0.payloadStringValue,
                    box: denormalize($0.boundingBox, width: w, height: h))
        }
    }

    // MARK: - Faces

    /// Face boxes, pixel rects in image coordinates, top-left origin.
    static func detectFaces(in cgImage: CGImage) async throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let observations = try await perform(request, on: cgImage)
            .compactMap { $0 as? VNFaceObservation }
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        return observations.map { denormalize($0.boundingBox, width: w, height: h) }
    }

    // MARK: - Sensitive info

    /// Pixel boxes (top-left origin) covering likely-sensitive text: email
    /// addresses, phone numbers, credit-card numbers (Luhn-verified), API
    /// keys, and person names (on-device named-entity recognition).
    /// Boxes are merged and generously padded — redaction errs on the side
    /// of covering too much rather than too little.
    static func detectSensitiveRegions(in cgImage: CGImage) async throws -> [CGRect] {
        sensitiveBoxes(in: try await recognizeText(in: cgImage))
    }

    /// Pure PII logic over OCR lines — no image needed, so unit tests can
    /// drive it directly.
    static func sensitiveBoxes(in lines: [TextLine]) -> [CGRect] {
        var boxes: [CGRect] = []
        for line in lines {
            boxes += regexBoxes(in: line)
        }
        boxes += nameBoxes(in: lines)
        return mergeOverlapping(boxes)
    }

    // MARK: - Plumbing

    /// Runs a Vision request off the main thread.
    static func perform(_ request: VNRequest,
                               on cgImage: CGImage) async throws -> [VNObservation] {
        try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0 as? VNObservation }
        }.value
    }

    /// Vision normalized boxes use a bottom-left origin; convert to
    /// top-left-origin pixel rects.
    static func denormalize(_ r: CGRect, width w: CGFloat,
                                   height h: CGFloat) -> CGRect {
        CGRect(x: r.minX * w,
               y: (1 - r.maxY) * h,
               width: r.width * w,
               height: r.height * h)
    }

    // MARK: - PII patterns

    struct PIIPattern {
        var regex: String
        var isValid: (String) -> Bool = { _ in true }
    }

    static let piiPatterns: [PIIPattern] = [
        // Email addresses.
        PIIPattern(regex: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#),
        // Phone numbers: needs 10+ digits, or an explicit + / ( area code,
        // so dates like 2026-09-21 don't match.
        PIIPattern(regex: #"\+?\d[\d\s().\-]{5,}\d"#) { s in
            let digits = s.filter(\.isNumber).count
            return digits >= 10 || s.contains("+") || s.contains("(")
        },
        // Credit-card numbers, Luhn-verified to cut false positives.
        PIIPattern(regex: #"(?:\d[ -]?){13,19}"#, isValid: isCardNumber),
        // Common API key shapes.
        PIIPattern(regex: #"\b(sk-[A-Za-z0-9_\-]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{16,}|xox[bpas]-[A-Za-z0-9\-]{8,}|AIza[0-9A-Za-z_\-]{35})\b"#),
    ]

    static func isCardNumber(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }

    static func regexBoxes(in line: TextLine) -> [CGRect] {
        var boxes: [CGRect] = []
        let ns = line.text as NSString
        for pattern in piiPatterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern.regex, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: line.text,
                                       range: NSRange(location: 0, length: ns.length)) {
                let matched = ns.substring(with: match.range)
                guard pattern.isValid(matched) else { continue }
                boxes.append(estimatedBox(for: match.range, in: line))
            }
        }
        return boxes
    }

    /// Finds person names with on-device NER and maps them back to line boxes.
    static func nameBoxes(in lines: [TextLine]) -> [CGRect] {
        let fullText = lines.map(\.text).joined(separator: "\n")
        guard !fullText.isEmpty else { return [] }
        // Character offsets of each line within fullText.
        var lineSpans: [(line: TextLine, start: Int, end: Int)] = []
        var cursor = 0
        for line in lines {
            let len = (line.text as NSString).length
            lineSpans.append((line, cursor, cursor + len))
            cursor += len + 1 // newline separator
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = fullText
        var boxes: [CGRect] = []
        let range = fullText.startIndex..<fullText.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, tokenRange in
            guard tag == .personalName else { return true }
            let nsRange = NSRange(tokenRange, in: fullText)
            for (line, start, end) in lineSpans
            where nsRange.location < end && NSMaxRange(nsRange) > start {
                let lo = max(nsRange.location, start) - start
                let hi = min(NSMaxRange(nsRange), end) - start
                boxes.append(estimatedBox(for: NSRange(location: lo, length: hi - lo),
                                          in: line))
            }
            return true
        }
        return boxes
    }

    /// Approximates a substring's box as a proportional slice of its line,
    /// padded generously — safe for redaction.
    static func estimatedBox(for range: NSRange, in line: TextLine) -> CGRect {
        let total = max((line.text as NSString).length, 1)
        let x0 = line.box.minX + line.box.width * CGFloat(range.location) / CGFloat(total)
        let x1 = line.box.minX + line.box.width * CGFloat(range.location + range.length) / CGFloat(total)
        let pad: CGFloat = 5
        return CGRect(x: x0 - pad,
                      y: line.box.minY - pad,
                      width: (x1 - x0) + pad * 2,
                      height: line.box.height + pad * 2)
    }

    static func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects {
            var merged = rect
            result = result.filter { other in
                if other.intersects(merged) {
                    merged = merged.union(other)
                    return false
                }
                return true
            }
            result.append(merged)
        }
        return result
    }
}

// MARK: - Geometry helpers

extension CGRect {
    /// Expands the rect by `fraction` of its size on every side.
    func padded(_ fraction: CGFloat) -> CGRect {
        insetBy(dx: -width * fraction, dy: -height * fraction)
    }

    /// Scales x, y, width, height by a constant factor.
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: origin.x * factor, y: origin.y * factor,
               width: width * factor, height: height * factor)
    }
}
