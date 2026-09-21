import SwiftUI
import AppKit

// MARK: - Pin to screen (Shottr-style floating screenshot)

/// A borderless, always-on-top, non-activating panel showing a screenshot.
/// Drag to move, drag edges to resize, hover for the close button.
final class PinWindowController {
    private let panel: NSPanel
    var onClose: (() -> Void)?

    init(image: NSImage) {
        // Cap the initial size; the window is resizable afterwards.
        let maxDim: CGFloat = 640
        let size = image.size
        let scale = min(1.0, maxDim / max(size.width, size.height))
        let winSize = NSSize(width: max(size.width * scale, 120),
                             height: max(size.height * scale, 120))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = true

        let root = PinView(image: image) { [weak panel] in panel?.close() }
        panel.contentView = PinHostingView(rootView: root)
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.onClose?() }

        // Start near the center of the main screen, slightly offset.
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: vf.midX - winSize.width / 2 + CGFloat(Int.random(in: -80...80)),
                y: vf.midY - winSize.height / 2 + CGFloat(Int.random(in: -80...80))
            ))
        }
        panel.orderFront(nil)
    }

    func close() { panel.close() }
}

/// Hosting view that lets the borderless window be dragged by its content.
private final class PinHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDownCanMoveWindow() -> Bool { true }
}

private struct PinView: View {
    let image: NSImage
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .shadow(radius: 4)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Close pin")
            }
        }
        .onHover { hovering = $0 }
    }
}
