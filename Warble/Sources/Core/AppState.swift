import Foundation
import SwiftUI

/// Speech engines the user can choose between. Both run entirely on this Mac.
enum RecognitionModel: String, CaseIterable, Identifiable {
    case appleOnDevice
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleOnDevice: return "Apple on-device (built in)"
        case .parakeet: return "NVIDIA Parakeet (Hugging Face)"
        }
    }

    var summary: String {
        switch self {
        case .appleOnDevice:
            return "Built into macOS. Smooth live typing and nothing to download."
        case .parakeet:
            return "Faster, better with names and jargon from your Word List, and re-reads each call recording when the call ends for a cleaner transcript. Downloads about 700 MB once."
        }
    }
}

/// App-wide settings, saved automatically between launches.
@MainActor
final class AppState: ObservableObject {
    private let defaults: UserDefaults

    @Published var dictationEnabled: Bool {
        didSet { defaults.set(dictationEnabled, forKey: Keys.dictationEnabled) }
    }
    @Published var recognitionModel: RecognitionModel {
        didSet { defaults.set(recognitionModel.rawValue, forKey: Keys.recognitionModel) }
    }
    @Published var dictationKey: DictationKey {
        didSet { defaults.set(dictationKey.rawValue, forKey: Keys.dictationKey) }
    }
    @Published var liveTyping: Bool {
        didSet { defaults.set(liveTyping, forKey: Keys.liveTyping) }
    }
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }
    @Published var promptForCalls: Bool {
        didSet { defaults.set(promptForCalls, forKey: Keys.promptForCalls) }
    }
    @Published var callApps: [String] {
        didSet { defaults.set(callApps, forKey: Keys.callApps) }
    }
    @Published var masterFolderPath: String {
        didSet { defaults.set(masterFolderPath, forKey: Keys.masterFolderPath) }
    }

    static let defaultCallApps = ["Microsoft Teams", "Zoom", "Google Meet", "Webex", "Slack", "FaceTime"]

    static var defaultMasterFolder: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return documents.appendingPathComponent("Warble").path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateSettingsFromGabble(into: defaults)
        dictationEnabled = defaults.object(forKey: Keys.dictationEnabled) as? Bool ?? true
        recognitionModel = RecognitionModel(rawValue: defaults.string(forKey: Keys.recognitionModel) ?? "")
            ?? .appleOnDevice
        dictationKey = DictationKey(rawValue: defaults.string(forKey: Keys.dictationKey) ?? "") ?? .fn
        liveTyping = defaults.object(forKey: Keys.liveTyping) as? Bool ?? true
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        promptForCalls = defaults.object(forKey: Keys.promptForCalls) as? Bool ?? true
        callApps = defaults.stringArray(forKey: Keys.callApps) ?? Self.defaultCallApps
        masterFolderPath = defaults.string(forKey: Keys.masterFolderPath) ?? Self.defaultMasterFolder
    }

    /// The app was renamed from Gabble to Warble, which changed where macOS keeps
    /// its settings. Copy the old settings across once.
    private static func migrateSettingsFromGabble(into defaults: UserDefaults) {
        guard defaults === UserDefaults.standard,
              !defaults.bool(forKey: "migratedFromGabble"),
              let old = UserDefaults(suiteName: "com.warth0g.gabble") else { return }
        let keys = ["dictationEnabled", "recognitionModel", "cleanupEnabled", "dictationKey",
                    "promptForCalls", "callApps", "masterFolderPath", "systemAudioRequested"]
        for key in keys {
            if let value = old.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromGabble")
    }

    private enum Keys {
        static let dictationEnabled = "dictationEnabled"
        static let recognitionModel = "recognitionModel"
        static let cleanupEnabled = "cleanupEnabled"
        static let liveTyping = "liveTyping"
        static let dictationKey = "dictationKey"
        static let promptForCalls = "promptForCalls"
        static let callApps = "callApps"
        static let masterFolderPath = "masterFolderPath"
    }
}
