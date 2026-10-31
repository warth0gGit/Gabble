import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Speech

/// Tracks the macOS permissions Gabble needs and helps the user grant them.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notAsked, needsRelaunch

        var label: String {
            switch self {
            case .granted: return "Allowed"
            case .denied: return "Not allowed"
            case .notAsked: return "Not set up yet"
            case .needsRelaunch: return "If you've switched Gabble on in System Settings, quit and reopen Gabble to finish."
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case microphone, speechRecognition, accessibility, systemAudio

        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech recognition"
            case .accessibility: return "Accessibility"
            case .systemAudio: return "Call audio recording"
            }
        }

        var explanation: String {
            switch self {
            case .microphone:
                return "So Gabble can hear you when you dictate or are on a call."
            case .speechRecognition:
                return "So Gabble can turn speech into text on this Mac. Nothing is sent to the cloud."
            case .accessibility:
                return "So Gabble can type your words into whatever app you are using, like Claude or Word."
            case .systemAudio:
                return "So Gabble can hear the other people on Teams or Zoom calls. Needed for call transcription."
            }
        }

        var settingsURL: URL? {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone: return URL(string: base + "Privacy_Microphone")
            case .speechRecognition: return URL(string: base + "Privacy_SpeechRecognition")
            case .accessibility: return URL(string: base + "Privacy_Accessibility")
            case .systemAudio: return URL(string: base + "Privacy_ScreenCapture")
            }
        }

        /// Permissions needed for dictation, the first feature.
        var requiredForDictation: Bool { self != .systemAudio }
    }

    @Published private(set) var statuses: [Kind: Status] = [:]

    private var systemAudioRequested: Bool {
        get { UserDefaults.standard.bool(forKey: "systemAudioRequested") }
        set { UserDefaults.standard.set(newValue, forKey: "systemAudioRequested") }
    }

    init() { refresh() }

    var allRequiredGranted: Bool {
        Kind.allCases.filter(\.requiredForDictation).allSatisfy { statuses[$0] == .granted }
    }

    func status(_ kind: Kind) -> Status { statuses[kind] ?? .notAsked }

    func refresh() {
        var updated: [Kind: Status] = [:]

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: updated[.microphone] = .granted
        case .notDetermined: updated[.microphone] = .notAsked
        default: updated[.microphone] = .denied
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: updated[.speechRecognition] = .granted
        case .notDetermined: updated[.speechRecognition] = .notAsked
        default: updated[.speechRecognition] = .denied
        }

        updated[.accessibility] = AXIsProcessTrusted() ? .granted : .notAsked

        // Call audio is captured with ScreenCaptureKit, which is covered by the
        // "Screen & System Audio Recording" permission. macOS only reports a new
        // grant after Gabble is relaunched.
        if CGPreflightScreenCaptureAccess() {
            updated[.systemAudio] = .granted
        } else {
            updated[.systemAudio] = systemAudioRequested ? .needsRelaunch : .notAsked
        }

        statuses = updated
    }

    func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in self.refresh() }
            }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openSettings(for: kind)
        case .systemAudio:
            if !CGRequestScreenCaptureAccess() {
                openSettings(for: kind)
            }
            systemAudioRequested = true
            refresh()
        }
    }

    func openSettings(for kind: Kind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}
