import Foundation

// Everything in this file is optional: it only compiles when the build SDK
// contains the framework, and only runs on a new enough OS. build.sh
// weak-links these frameworks so the app still launches on older macOS.

#if canImport(FoundationModels)
import FoundationModels

/// On-device LLM features via Apple Intelligence.
/// Requires macOS 26+ on Apple Silicon with Apple Intelligence enabled.
enum SmartText {
    @available(macOS 26, *)
    static func isAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Suggests a short kebab-case file name from the screenshot's text.
    @available(macOS 26, *)
    static func suggestFilename(for ocrText: String,
                                appName: String?) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You suggest short file names for screenshots. Reply with ONLY the \
            file name: lowercase, words separated by hyphens, no extension, \
            max 6 words, no quotes, no explanation.
            """)
        var prompt = "Suggest a file name for a screenshot"
        if let app = appName, !app.isEmpty { prompt += " taken in \(app)" }
        let content = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt += content.isEmpty
            ? "."
            : " containing this text:\n\(content.prefix(2000))"
        let response = try await session.respond(to: prompt)
        return sanitize(response.content)
    }

    /// Summarizes the screenshot's text in a couple of sentences.
    @available(macOS 26, *)
    static func summarize(_ ocrText: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            Summarize the given text briefly in 2-3 sentences. \
            Reply with only the summary.
            """)
        let response = try await session.respond(
            to: "Summarize this text:\n\(ocrText.prefix(4000))")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps whatever the model returned filesystem-safe.
    private static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = trimmed.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let name = parts.joined(separator: "-")
        return name.isEmpty ? "screenshot" : String(name.prefix(80))
    }
}
#endif

#if canImport(Translation)
import Translation

/// On-device translation. Requires macOS 15+; the system downloads language
/// models on first use.
enum LocalTranslate {
    @available(macOS 15, *)
    static func translate(_ text: String,
                          to target: Locale.Language) async throws -> String {
        let config = TranslationSession.Configuration(source: nil, target: target)
        let session = TranslationSession(configuration: config)
        try await session.prepareForTranslation()
        let response = try await session.translate(text)
        return response.targetText
    }

    static let commonLanguages: [(id: String, label: String)] = [
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
    ]
}
#endif
