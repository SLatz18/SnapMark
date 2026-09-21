import SwiftUI
import AppKit
import CoreGraphics
import ServiceManagement

@main
struct SnapMarkApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("SnapMark", systemImage: "camera.viewfinder") {
            Button("Capture Region  (⌃⇧5)") {
                appState.captureRegion()
            }
            Divider()
            SettingsLink()
            Button("Screen Recording Permissions…") {
                appState.openScreenRecordingSettings()
            }
            Divider()
            Button("Quit SnapMark") {
                NSApplication.shared.terminate(nil)
            }
        }
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App state

final class AppState: ObservableObject {
    private let hotKeys = HotKeyManager.shared
    private var editorWindows: [NSWindow] = []
    private var capturing = false

    init() {
        hotKeys.onHotKey = { [weak self] in self?.captureRegion() }
        hotKeys.register()
    }

    func captureRegion() {
        // The Carbon callback can fire on a background thread; hop to main.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.captureRegion() }
            return
        }
        guard !capturing else { return }
        capturing = true
        Task {
            defer { capturing = false }
            guard CGPreflightScreenCaptureAccess() else {
                showPermissionAlert()
                return
            }
            guard let image = await ScreenshotService.captureRegion() else { return }
            openEditor(with: image)
        }
    }

    func openEditor(with image: NSImage) {
        let document = AnnotationDocument(image: image)
        let window = NSWindow(
            contentRect: EditorWindowSizing.frame(for: image),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapMark"
        window.contentView = NSHostingView(rootView: EditorView(document: document))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindows.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.editorWindows.removeAll { $0 == window }
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showPermissionAlert() {
        // Triggers the system prompt on first run.
        _ = CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "SnapMark needs Screen Recording permission"
        alert.informativeText = "To capture your screen, allow SnapMark in System Settings → Privacy & Security → Screen Recording, then press ⌃⇧5 again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLogin = newValue
                    } catch {
                        // Leave the toggle off if registration failed
                        // (works best when SnapMark is in /Applications).
                    }
                }
            ))
            Text("Press Ctrl+Shift+5 anywhere to capture a region.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320)
    }
}
