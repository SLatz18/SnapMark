import Foundation
import AppKit
import ImageIO

// MARK: - Screenshot metadata

/// Date/time, user, and source-app ("site") info captured at the moment a
/// screenshot is taken. Embedded into saved PNGs and shown in the editor.
struct ScreenshotMetadata {
    var capturedAt: Date
    var userName: String          // macOS short login name, e.g. "slatz18"
    var fullUserName: String      // e.g. "Austin Latz"
    var frontAppName: String?     // frontmost app when captured, e.g. "Safari"
    var frontAppBundleID: String? // e.g. "com.apple.Safari"
    var hostName: String?
    var pageURL: String?          // active browser tab URL, when captured from a browser

    /// Grabs "now + who + where". Call on the main thread at capture time,
    /// before the system capture UI takes over the screen.
    static func capture() -> ScreenshotMetadata {
        let front = NSWorkspace.shared.frontmostApplication
        return ScreenshotMetadata(
            capturedAt: Date(),
            userName: NSUserName(),
            fullUserName: NSFullUserName(),
            frontAppName: front?.localizedName,
            frontAppBundleID: front?.bundleIdentifier,
            hostName: Host.current().localizedName,
            pageURL: BrowserURLCapture.activePageURL()
        )
    }

    /// One-line summary for the editor, e.g.
    /// "Sep 21, 2026, 8:30 AM · slatz18 · Safari · example.com/…".
    var summaryLine: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        var parts = [fmt.string(from: capturedAt), userName]
        if let app = frontAppName { parts.append(app) }
        if let url = pageURL {
            parts.append(url.count > 64 ? String(url.prefix(61)) + "..." : url)
        }
        return parts.joined(separator: " · ")
    }

    /// ImageIO PNG-dictionary properties, written as tEXt chunks in the file.
    var pngProperties: [String: String] {
        let iso = ISO8601DateFormatter().string(from: capturedAt)
        let author = fullUserName.isEmpty ? userName : fullUserName
        var description = "Captured \(iso) by \(userName)"
        if let host = hostName { description += " on \(host)" }
        if let app = frontAppName {
            description += " in \(app)"
            if let bid = frontAppBundleID { description += " (\(bid))" }
        }
        if let url = pageURL { description += " — \(url)" }
        return [
            kCGImagePropertyPNGTitle as String: "SnapMark Screenshot",
            kCGImagePropertyPNGAuthor as String: author,
            kCGImagePropertyPNGDescription as String: description,
            kCGImagePropertyPNGCreationTime as String: iso,
            kCGImagePropertyPNGSoftware as String: "SnapMark",
        ]
    }
}
