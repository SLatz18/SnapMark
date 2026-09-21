import Foundation
import SwiftUI

// MARK: - Configurable metadata stamp (zIPE-inspired)
//
// Replaces the old fixed URL caption bar with a configurable badge burned
// onto exported images (saved, copied, pinned). Fields are toggleable and
// reorderable; position, size and background opacity are adjustable; the
// Settings pane shows a live preview.

enum StampField: String, CaseIterable, Codable {
    case customText
    case userName
    case timestamp
    case appName
    case pageURL

    var label: String {
        switch self {
        case .customText: return "Custom text"
        case .userName: return "Username"
        case .timestamp: return "Date & time"
        case .appName: return "App name"
        case .pageURL: return "Page URL"
        }
    }
}

struct StampFieldSetting: Codable, Identifiable {
    var id: String { field.rawValue }
    var field: StampField
    var enabled: Bool
}

enum StampPosition: String, CaseIterable, Codable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum StampSize: String, CaseIterable, Codable {
    case small
    case medium
    case large

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

struct StampSettings: Codable {
    var enabled: Bool = true
    var fields: [StampFieldSetting] = [
        StampFieldSetting(field: .userName, enabled: true),
        StampFieldSetting(field: .appName, enabled: true),
        StampFieldSetting(field: .pageURL, enabled: true),
        StampFieldSetting(field: .timestamp, enabled: true),
        StampFieldSetting(field: .customText, enabled: false),
    ]
    var customText: String = ""
    var position: StampPosition = .bottomRight
    var size: StampSize = .medium
    var backgroundOpacity: Double = 0.55
    var showFullTimezone: Bool = false

    private static let storageKey = "stampSettingsV1"

    static func load() -> StampSettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(StampSettings.self, from: data) {
            return decoded
        }
        // Migrate the pre-stamp single toggle ("Imprint browser URL on screenshots").
        var settings = StampSettings()
        if let old = UserDefaults.standard.object(forKey: "imprintPageURL") as? Bool {
            settings.enabled = old
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func isFieldEnabled(_ field: StampField) -> Bool {
        fields.first(where: { $0.field == field })?.enabled ?? false
    }
}

/// Observable store for the Settings UI. Writes through to UserDefaults.
final class StampSettingsStore: ObservableObject {
    @Published var settings: StampSettings {
        didSet { settings.save() }
    }

    init() {
        self.settings = StampSettings.load()
    }
}
