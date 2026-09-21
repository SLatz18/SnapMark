import AppKit
import Foundation

/// Region capture using the system `screencapture` tool, so the selection UI
/// and image quality match macOS exactly.
enum ScreenshotService {
    /// Shows the native crosshair selector. Returns nil if the user cancels (Esc)
    /// or if capture fails.
    static func captureRegion() async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("snapmark-\(UUID().uuidString).png")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i interactive selection, -x no shutter sound, -t png
                process.arguments = ["-i", "-x", "-t", "png", tmpURL.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                guard process.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: tmpURL.path),
                      let image = NSImage(contentsOf: tmpURL) else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    continuation.resume(returning: nil)
                    return
                }
                try? FileManager.default.removeItem(at: tmpURL)
                continuation.resume(returning: image)
            }
        }
    }
}
