import AppKit
import Foundation

// MARK: - Stamp badge drawing

/// Burns the configured metadata badge onto an image context.
/// Called inside a flipped lockFocus context (origin top-left), the same
/// convention the editor's renderer uses.
enum StampRenderer {
    static func drawStamp(_ settings: StampSettings,
                          metadata: ScreenshotMetadata,
                          in ctx: CGContext,
                          imageSize: CGSize) {
        guard settings.enabled else { return }
        let parts = settings.fields.compactMap { fieldSetting -> String? in
            guard fieldSetting.enabled else { return nil }
            return metadata.stampValue(for: fieldSetting.field, settings: settings)
        }
        guard !parts.isEmpty else { return }

        let fontSize = fontSize(for: settings.size, imageWidth: imageSize.width)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]

        // Truncate the whole line until it fits the image width.
        var display = parts.joined(separator: " | ")
        let maxW = imageSize.width * 0.92
        while (display as NSString).size(withAttributes: attrs).width > maxW,
              display.count > 12 {
            display = String(display.dropLast(12)) + "…"
        }

        let textSize = (display as NSString).size(withAttributes: attrs)
        let padX = fontSize * 0.7
        let padY = fontSize * 0.5
        let boxW = textSize.width + padX * 2
        let boxH = textSize.height + padY * 2
        let margin: CGFloat = 14

        let x: CGFloat
        switch settings.position {
        case .topLeft, .bottomLeft:
            x = margin
        case .topRight, .bottomRight:
            x = imageSize.width - boxW - margin
        }
        let y: CGFloat
        switch settings.position {
        case .topLeft, .topRight:
            y = margin
        case .bottomLeft, .bottomRight:
            y = imageSize.height - boxH - margin
        }

        let box = CGRect(x: x, y: y, width: boxW, height: boxH)
        ctx.setFillColor(NSColor(white: 0, alpha: CGFloat(settings.backgroundOpacity)).cgColor)
        let path = CGPath(roundedRect: box,
                          cornerWidth: boxH * 0.35,
                          cornerHeight: boxH * 0.35,
                          transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        (display as NSString).draw(
            at: CGPoint(x: x + padX, y: y + padY),
            withAttributes: attrs
        )
    }

    /// Font scales with image width so the badge reads the same on a
    /// 800px window grab and a 3000px retina capture.
    private static func fontSize(for size: StampSize, imageWidth: CGFloat) -> CGFloat {
        let factor: CGFloat
        switch size {
        case .small: factor = 0.016
        case .medium: factor = 0.022
        case .large: factor = 0.030
        }
        return min(max(imageWidth * factor, 11), 44)
    }

    // MARK: - Settings live preview

    /// A fake screenshot with the stamp drawn on it, for the Settings pane.
    static func previewImage(settings: StampSettings,
                             size: CGSize = CGSize(width: 360, height: 200)) -> NSImage {
        let image = NSImage(size: size, flipped: true)
        image.lockFocus()

        // Fake page content: light backdrop with a couple of "windows".
        NSColor(white: 0.72, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: size.width - 48, height: 44),
                     xRadius: 8, yRadius: 8).fill()
        NSColor(white: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 84, width: size.width * 0.55, height: size.height - 108),
                     xRadius: 8, yRadius: 8).fill()
        NSColor.systemBlue.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: size.width * 0.65, y: 84, width: size.width * 0.28, height: 60),
                     xRadius: 8, yRadius: 8).fill()

        if let ctx = NSGraphicsContext.current?.cgContext {
            let sample = ScreenshotMetadata(
                capturedAt: Date(),
                userName: NSUserName(),
                fullUserName: NSFullUserName(),
                frontAppName: "Safari",
                frontAppBundleID: "com.apple.Safari",
                hostName: nil,
                pageURL: "https://example.com/docs/getting-started?ref=nav#top",
                urlCaptureAttempted: true
            )
            drawStamp(settings, metadata: sample, in: ctx, imageSize: size)
        }

        image.unlockFocus()
        return image
    }
}
