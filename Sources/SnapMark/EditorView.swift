import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var document: AnnotationDocument
    /// Called with the fully rendered image; the host pins it to the screen
    /// and closes this editor window.
    let onPin: (NSImage) -> Void
    @State private var textBuffer = ""
    @FocusState private var textFieldFocused: Bool
    @StateObject private var drive = DriveUploader.shared
    @State private var isUploading = false
    @State private var uploadNotice: String?
    @State private var uploadError: String?

    var body: some View {
        ZStack {
            CanvasRepresentable(document: document)

            // Floating pills, top-center: tools + style.
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    toolsPill
                    stylePill
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                Spacer(minLength: 0)
            }

            // Floating actions, bottom-right.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    floatingActions
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }

            // Capture metadata, bottom-left.
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if document.urlCaptureWarningNeeded {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Couldn't read the browser URL — SnapMark needs Automation permission.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") { openAutomationSettings() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .modifier(FloatingPill())
                    .padding(.leading, 12)
                }
                HStack(spacing: 0) {
                    Text(document.metadata.summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .modifier(FloatingPill())
                        .padding(.leading, 12)
                        .padding(.bottom, 12)
                    Spacer(minLength: 0)
                }
            }

            if document.pendingTextPoint != nil {
                textOverlay
            }
        }
        .frame(minWidth: 900, minHeight: 420)
    }

    // MARK: - Tool pill

    private var toolsPill: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                Button {
                    document.tool = tool
                    document.cancelPendingText()
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .foregroundStyle(document.tool == tool ? .white : .primary)
                        .background {
                            if document.tool == tool {
                                Circle().fill(Color.accentColor)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tool.label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(FloatingPill())
    }

    // MARK: - Style pill

    private var stylePill: some View {
        HStack(spacing: 6) {
            ForEach(MarkColor.palette, id: \.self) { c in
                colorSwatch(c)
            }
            if let custom = document.customColor {
                colorSwatch(custom, help: "Picked color")
            }

            Divider().frame(height: 20)

            VStack(spacing: 0) {
                Text("Size").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $document.lineWidth, in: 1...24, step: 1)
                    .frame(width: 80)
            }
            .help("Line width")

            Button {
                document.fillShapes.toggle()
            } label: {
                Image(systemName: document.fillShapes ? "square.fill" : "square")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(document.fillShapes ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Fill shapes")

            Button {
                document.sketchStyle.toggle()
            } label: {
                Image(systemName: "scribble")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(document.sketchStyle ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Hand-drawn style")

            Divider().frame(height: 20)

            Button { document.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(document.canUndo ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!document.canUndo)
            .help("Undo (⌘Z)")

            Button { document.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(document.canRedo ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!document.canRedo)
            .help("Redo (⇧⌘Z)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(FloatingPill())
    }

    private func colorSwatch(_ c: MarkColor, help: String = "Stroke color") -> some View {
        Button {
            document.color = c
        } label: {
            Circle()
                .fill(c.color)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(0.6),
                        lineWidth: document.color == c ? 2 : 0.75
                    )
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Floating actions

    private var floatingActions: some View {
        HStack(spacing: 10) {
            if document.draftCropRect != nil {
                Button("Apply Crop") { document.applyCropFromDraft() }
                    .keyboardShortcut(.return, modifiers: [])
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.borderless)
                Button("Cancel") { document.draftCropRect = nil }
                    .buttonStyle(.borderless)
                Divider().frame(height: 20)
            }
            Button { onPin(document.renderedImage()) } label: {
                Label("Pin", systemImage: "pin")
            }
            .help("Pin to screen — floats above all windows")
            .buttonStyle(.borderless)
            Button("Copy") { document.copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy PNG to clipboard (⌘C)")
                .buttonStyle(.borderless)
            Button("Save…") { document.saveToFile() }
                .keyboardShortcut("s", modifiers: .command)
                .help("Save PNG (⌘S)")
                .buttonStyle(.borderless)
            uploadButton
            if let notice = uploadNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(FloatingPill())
    }

    // MARK: - Drive upload

    private var uploadButton: some View {
        Button {
            Task { await uploadScreenshot() }
        } label: {
            if isUploading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                Label("Upload", systemImage: "icloud.and.arrow.up")
            }
        }
        .disabled(isUploading || !drive.isConfigured)
        .help(drive.isConfigured
              ? "Upload to Google Drive and copy the share link (⌘U)"
              : "Set your Google OAuth client ID in Settings to enable uploads")
        .keyboardShortcut("u", modifiers: .command)
        .buttonStyle(.borderless)
        .alert("Upload failed",
               isPresented: Binding(get: { uploadError != nil },
                                    set: { if !$0 { uploadError = nil } }),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(uploadError ?? "") })
    }

    private func uploadScreenshot() async {
        guard let png = document.pngData() else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let link = try await drive.upload(
                pngData: png,
                filename: document.suggestedFileName(),
                description: document.metadata.driveDescription)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(link, forType: .string)
            uploadNotice = "Link copied to clipboard"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            uploadNotice = nil
        } catch {
            uploadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func openAutomationSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Text overlay

    private var textOverlay: some View {
        TextField("Type text…", text: $textBuffer, onCommit: {
            document.commitPendingText(textBuffer)
            textBuffer = ""
        })
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 14))
        .frame(width: 240)
        .position(x: (document.pendingTextPoint?.x ?? 0) + 122,
                  y: (document.pendingTextPoint?.y ?? 0) + 16)
        .focused($textFieldFocused)
        .onAppear { textBuffer = ""; textFieldFocused = true }
        .onExitCommand { document.cancelPendingText() }
    }
}

// MARK: - Floating pill material

/// Liquid Glass capsule on macOS 26+, frosted material on older releases.
private struct FloatingPill: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content.background(.regularMaterial, in: Capsule())
            }
        }
    }
}

// MARK: - Window sizing

enum EditorWindowSizing {
    /// Fits the screenshot into 92% × 86% of the visible screen, plus a little
    /// padding. Never upscales beyond 1×. Toolbars float over the canvas, so
    /// no extra room is reserved for them.
    static func frame(for image: NSImage) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.92
        let maxH = screen.height * 0.86
        let img = image.size
        let s = min(maxW / img.width, maxH / img.height, 1.0)
        return NSRect(x: 0, y: 0, width: img.width * s + 24, height: img.height * s + 24)
    }
}
