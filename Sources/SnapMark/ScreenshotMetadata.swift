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
    /// True when the frontmost app at capture time was a supported browser
    /// but no URL could be read (usually denied Automation permission).
    var urlCaptureAttempted: Bool

    /// Grabs "now + who + where". Call on the main thread at capture time,
    /// before the system capture UI takes over the screen.
    static func capture() -> ScreenshotMetadata {
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        return ScreenshotMetadata(
            capturedAt: Date(),
            userName: NSUserName(),
            fullUserName: NSFullUserName(),
            frontAppName: front?.localizedName,
            frontAppBundleID: bundleID,
            hostName: Host.current().localizedName,
            pageURL: BrowserURLCapture.activePageURL(),
            urlCaptureAttempted: BrowserURLCapture.isSupportedBrowser(bundleID: bundleID)
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

    // MARK: - Stamp fields

    /// Display string for one stamp field, or nil when it has no value.
    func stampValue(for field: StampField, settings: StampSettings) -> String? {
        switch field {
        case .customText:
            let text = settings.customText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case .userName:
            return userName.isEmpty ? nil : userName
        case .timestamp:
            return Self.stampTimestamp(capturedAt, fullZone: settings.showFullTimezone)
        case .appName:
            return frontAppName
        case .pageURL:
            guard let url = pageURL, !url.isEmpty else { return nil }
            return Self.displayURL(url)
        }
    }

    static func stampTimestamp(_ date: Date, fullZone: Bool) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        var text = fmt.string(from: date)
        if fullZone {
            text += " (\(TimeZone.current.identifier))"
        }
        return text
    }

    /// hostname + path, no query string or fragment — mirrors zIPE's
    /// formatUrlForStamp.
    static func displayURL(_ url: String, maxLength: Int = 60) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        let port = parsed.port.map { ":\($0)" } ?? ""
        var display = host + port + parsed.path
        if parsed.path == "/" || parsed.path.isEmpty {
            display = host + port
        }
        if display.count > maxLength {
            display = String(display.prefix(maxLength - 3)) + "..."
        }
        return display
    }

    // MARK: - Filenames & sharing

    /// Filesystem-safe source token for filenames: URL host, else app name.
    /// e.g. "example.com", "Safari".
    var fileSourceName: String {
        let raw: String
        if let url = pageURL, let host = URL(string: url)?.host, !host.isEmpty {
            raw = host
        } else if let app = frontAppName, !app.isEmpty {
            raw = app
        } else {
            raw = "screenshot"
        }
        var safe = raw.replacingOccurrences(of: "[^a-zA-Z0-9._-]+",
                                            with: "_",
                                            options: .regularExpression)
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if safe.isEmpty { safe = "screenshot" }
        return String(safe.prefix(48))
    }

    /// Description attached to Drive uploads, zIPE-style.
    var driveDescription: String {
        var text = "Captured by \(userName)"
        if let url = pageURL, !url.isEmpty {
            text += " from \(url)"
        } else if let app = frontAppName {
            text += " in \(app)"
        }
        text += " at \(Self.stampTimestamp(capturedAt, fullZone: true))"
        return text
    }
}
