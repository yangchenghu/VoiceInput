import Foundation

enum InsertionMode: String, Codable, Equatable, Sendable {
    case unicode
    case clipboard
}

struct AppSettings: Codable, Equatable {
    var recordMode: RecordMode = .hold
    var hotkey: HotkeyBinding = .defaultRightCommand
    var correctionEnabled = false
    var correctionBaseURL = ""
    var correctionModel = ""
    var insertionMode: InsertionMode = .unicode
    var asrEndpoint = DoubaoDefaults.endpoint
    var asrResourceID = DoubaoDefaults.resourceID
    var asrAuthMode: ASRAuthMode = .apiKey
    var didShowOnboarding = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordMode = try container.decodeIfPresent(RecordMode.self, forKey: .recordMode) ?? .hold
        hotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey) ?? .defaultRightCommand
        correctionEnabled = try container.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? false
        correctionBaseURL = try container.decodeIfPresent(String.self, forKey: .correctionBaseURL) ?? ""
        correctionModel = try container.decodeIfPresent(String.self, forKey: .correctionModel) ?? ""
        insertionMode = try container.decodeIfPresent(InsertionMode.self, forKey: .insertionMode) ?? .unicode
        asrEndpoint = try container.decodeIfPresent(String.self, forKey: .asrEndpoint) ?? DoubaoDefaults.endpoint
        asrResourceID = try container.decodeIfPresent(String.self, forKey: .asrResourceID) ?? DoubaoDefaults.resourceID
        asrAuthMode = try container.decodeIfPresent(ASRAuthMode.self, forKey: .asrAuthMode) ?? .apiKey
        didShowOnboarding = try container.decodeIfPresent(Bool.self, forKey: .didShowOnboarding) ?? false
    }
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
