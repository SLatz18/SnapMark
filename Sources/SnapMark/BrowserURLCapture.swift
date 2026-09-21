import AppKit
import Foundation

/// Reads the active tab URL from the frontmost browser via AppleScript.
/// First use triggers the macOS Automation permission prompt
/// ("SnapMark would like to control Safari"), which the user must allow.
/// Returns nil for non-browsers, denied permission, or any script error.
enum BrowserURLCapture {
    private static let chromiumIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", // Arc
    ]

    static func activePageURL() -> String? {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return nil
        }
        let source: String
        if bundleID == "com.apple.Safari" {
            source = #"tell application "Safari" to get URL of front document"#
        } else if chromiumIDs.contains(bundleID) {
            source = #"tell application id "\#(bundleID)" to get URL of active tab of front window"#
        } else {
            return nil
        }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        let url = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url, !url.isEmpty else { return nil }
        return url
    }
}
