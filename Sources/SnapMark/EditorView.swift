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
    @State private var isAnalyzing = false
    @State private var aiNotice: String?
    @State private var barcodes: [LocalAI.Barcode] = []
    @AppStorage("aiDetectQR") private var aiDetectQR = true
    @AppStorage("translateTargetLang") private var translateLang = "es"

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
        .overlay(alignment: .top, content: barcodeChips)
        .onAppear(perform: detectBarcodes)
    }

    // MARK: - QR / barcode chips

    /// Scans for QR/barcode payloads once the editor opens.
    private func detectBarcodes() {
        Task {
            guard aiDetectQR,
                  let (cg, _) = aiImage() else { return }
            let found = (try? await LocalAI.detectBarcodes(in: cg)) ?? []
            barcodes = found.filter {
                guard let p = $0.payload else { return false }
                return !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    @ViewBuilder
    private func barcodeChips() -> some View {
        if !barcodes.isEmpty {
            VStack(spacing: 6) {
                ForEach(barcodes.indices, id: \.self) { i in
                    let payload = barcodes[i].payload ?? ""
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode")
                        Text(payload)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let url = URL(string: payload),
                           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            Button("Open") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.borderless)
                        }
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(payload, forType: .string)
                            flashAINotice("Copied to clipboard.")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .modifier(FloatingPill())
                }
            }
            .padding(.top, 52)
        }
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
                document.sketchStyle.toggle()
            } label: {
                Image(systemName: "scribble")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(document.sketchStyle ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help("Hand-drawn style")

            Menu {
                Picker("Stroke style", selection: $document.strokeStyle) {
                    ForEach(StrokeStyle.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
            } label: {
                Text(document.strokeStyle.label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44)
            }
            .help("Stroke style: solid, dashed, dotted")
            .menuStyle(.borderlessButton)

            Menu {
                Picker("Fill style", selection: $document.fillStyle) {
                    ForEach(FillStyle.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
            } label: {
                Text("Fill: \(document.fillStyle.label)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .help("Shape fill: none, solid, hachure, cross-hatch")
            .menuStyle(.borderlessButton)

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
            aiMenu
            if let notice = uploadNotice ?? aiNotice {
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

    // MARK: - On-device AI

    private var aiMenu: some View {
        Menu {
            Button("Redact faces") { redactFaces() }
            Button("Redact personal info") { redactSensitive() }
            Divider()
            Button("Copy text from image") { ocrToClipboard() }
            #if canImport(Translation)
            if #available(macOS 15, *) {
                Button("Translate text…") { translateToClipboard() }
            }
            #endif
            #if canImport(FoundationModels)
            if #available(macOS 26, *), SmartText.isAvailable() {
                Divider()
                Button("Summarize text") { summarizeToClipboard() }
                Button("Save with AI-suggested name…") { saveWithAIName() }
            }
            #endif
        } label: {
            if isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "sparkles")
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.borderless)
        .help("On-device AI: redact, OCR, translate")
        .disabled(isAnalyzing)
    }

    /// Vision works in pixels; the canvas works in points.
    private func aiImage() -> (cg: CGImage, scale: CGFloat)? {
        guard let cg = document.cgImageForAI() else { return nil }
        let scale = CGFloat(cg.width) / document.imageSize.width
        guard scale > 0 else { return nil }
        return (cg, scale)
    }

    private func flashAINotice(_ text: String) {
        aiNotice = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            aiNotice = nil
        }
    }

    private func redactFaces() {
        Task {
            guard let (cg, scale) = aiImage() else { return }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let faces = try await LocalAI.detectFaces(in: cg)
                guard !faces.isEmpty else {
                    flashAINotice("No faces found.")
                    return
                }
                let rects = faces.map { $0.padded(0.25).scaled(by: 1 / scale) }
                document.redact(rects: rects)
                flashAINotice("Redacted \(faces.count) face\(faces.count == 1 ? "" : "s").")
            } catch {
                flashAINotice("Face detection failed.")
            }
        }
    }

    private func redactSensitive() {
        Task {
            guard let (cg, scale) = aiImage() else { return }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let regions = try await LocalAI.detectSensitiveRegions(in: cg)
                guard !regions.isEmpty else {
                    flashAINotice("No personal info found.")
                    return
                }
                document.redact(rects: regions.map { $0.scaled(by: 1 / scale) })
                flashAINotice("Redacted \(regions.count) item\(regions.count == 1 ? "" : "s").")
            } catch {
                flashAINotice("Couldn't scan for personal info.")
            }
        }
    }

    private func ocrToClipboard() {
        Task {
            guard let (cg, _) = aiImage() else { return }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let text = try await LocalAI.plainText(in: cg)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    flashAINotice("No text found.")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                flashAINotice("Copied \(text.count) characters.")
            } catch {
                flashAINotice("Couldn't read text from the image.")
            }
        }
    }

    #if canImport(Translation)
    @available(macOS 15, *)
    private func translateToClipboard() {
        Task {
            guard let (cg, _) = aiImage() else { return }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let text = try await LocalAI.plainText(in: cg)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    flashAINotice("No text found.")
                    return
                }
                let target = Locale.Language(identifier: translateLang)
                let out = try await LocalTranslate.translate(text, to: target)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(out, forType: .string)
                flashAINotice("Translation copied to clipboard.")
            } catch {
                flashAINotice("Translation failed — the language model may still be downloading.")
            }
        }
    }
    #endif

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func summarizeToClipboard() {
        Task {
            guard let (cg, _) = aiImage() else { return }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let text = try await LocalAI.plainText(in: cg)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    flashAINotice("No text found.")
                    return
                }
                let summary = try await SmartText.summarize(text)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summary, forType: .string)
                flashAINotice("Summary copied to clipboard.")
            } catch {
                flashAINotice("Couldn't summarize the text.")
            }
        }
    }

    @available(macOS 26, *)
    private func saveWithAIName() {
        Task {
            guard let (cg, _) = aiImage() else { return }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let text = try await LocalAI.plainText(in: cg)
                let suggestion = try await SmartText.suggestFilename(
                    for: text, appName: document.metadata.frontAppName)
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
                let name = "SnapMark_\(suggestion)_\(fmt.string(from: document.metadata.capturedAt)).png"
                document.saveToFile(nameField: name)
            } catch {
                flashAINotice("Couldn't suggest a name.")
            }
        }
    }
    #endif

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
        .onAppear { textBuffer = document.textEditInitial; textFieldFocused = true }
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
