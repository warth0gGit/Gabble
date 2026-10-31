import Foundation
import SwiftUI

/// Speech engines the user can choose between. Only Apple's is wired up so far;
/// the others are placeholders for on-device Hugging Face models.
enum RecognitionModel: String, CaseIterable, Identifiable {
    case appleOnDevice
    case whisperLargeV3Turbo
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleOnDevice: return "Apple on-device (built in)"
        case .whisperLargeV3Turbo: return "Whisper Large v3 Turbo (Hugging Face)"
        case .parakeet: return "NVIDIA Parakeet (Hugging Face)"
        }
    }

    var isAvailable: Bool { self == .appleOnDevice }
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
        return documents.appendingPathComponent("Gabble").path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dictationEnabled = defaults.bool(forKey: Keys.dictationEnabled)
        recognitionModel = RecognitionModel(rawValue: defaults.string(forKey: Keys.recognitionModel) ?? "")
            ?? .appleOnDevice
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        promptForCalls = defaults.object(forKey: Keys.promptForCalls) as? Bool ?? true
        callApps = defaults.stringArray(forKey: Keys.callApps) ?? Self.defaultCallApps
        masterFolderPath = defaults.string(forKey: Keys.masterFolderPath) ?? Self.defaultMasterFolder
    }

    private enum Keys {
        static let dictationEnabled = "dictationEnabled"
        static let recognitionModel = "recognitionModel"
        static let cleanupEnabled = "cleanupEnabled"
        static let promptForCalls = "promptForCalls"
        static let callApps = "callApps"
        static let masterFolderPath = "masterFolderPath"
    }
}
