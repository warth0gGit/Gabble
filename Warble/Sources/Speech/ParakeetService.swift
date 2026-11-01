import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Parakeet speech recognition, run on this Mac's Neural Engine through
/// FluidAudio. The model downloads from Hugging Face once (about 600 MB), plus a
/// small second model (about 100 MB) that listens for Word List terms.
actor ParakeetService {
    static let shared = ParakeetService()
    static let sampleRate = 16_000

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var tail: Task<Void, Never>?
    private var ctcModels: CtcModels?
    private var boosting: (terms: [String], session: VocabularyBoostingSession)?
    private var boostingFailed = false

    /// English-only Parakeet is best at rare words and names; Ultra covers 25 languages.
    static var version: AsrModelVersion {
        Locale.current.language.languageCode?.identifier == "en" ? .v2 : .ultra
    }

    var isReady: Bool { manager != nil }

    /// Downloads (first time only) and loads the model. Safe to call repeatedly.
    @discardableResult
    func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let version = Self.version
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let loaded = try await task.value
            manager = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    /// Parakeet needs at least a moment of audio; short clips are padded with silence.
    static func padded(_ samples: [Float]) -> [Float] {
        let minimum = sampleRate
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    /// Transcribes 16 kHz mono samples.
    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        let manager = try await prepare()
        let audio = Self.padded(samples)
        return try await serialized {
            var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(audio, decoderState: &state)
        }
    }

    /// Transcribes an audio file in any format.
    func transcribe(file url: URL) async throws -> ASRResult {
        let manager = try await prepare()
        return try await serialized {
            var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(url, decoderState: &state)
        }
    }

    /// Fixes Word List terms (names, jargon) in a transcript by listening for
    /// them in the audio. Returns the original text if nothing needs changing
    /// or the vocabulary model isn't available.
    func boost(text: String, timings: [TokenTiming], audio: [Float], terms: [String]) async -> String {
        let terms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })).sorted()
        guard !terms.isEmpty, !timings.isEmpty, !audio.isEmpty,
              let session = await session(for: terms) else { return text }
        guard session.hasCTCRescoringCandidates(text: text, tokenTimings: timings) else { return text }
        guard let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: audio),
              output.wasModified else { return text }
        return output.text
    }

    private func session(for terms: [String]) async -> VocabularyBoostingSession? {
        if let boosting, boosting.terms == terms { return boosting.session }
        guard !boostingFailed else { return nil }
        do {
            let models: CtcModels
            if let ctcModels {
                models = ctcModels
            } else {
                models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                ctcModels = models
            }
            let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            let session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models)
            boosting = (terms, session)
            return session
        } catch {
            // Boosting is a bonus; transcription still works without it.
            boostingFailed = true
            return nil
        }
    }

    /// Runs one transcription at a time so the model's state isn't shared.
    private func serialized<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// Download status of the Parakeet model, shown in Settings.
@MainActor
final class ParakeetStatus: ObservableObject {
    static let shared = ParakeetStatus()

    enum State: Equatable {
        case unknown
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .unknown

    /// Starts downloading and loading the model in the background.
    func warmUp() {
        guard state != .downloading, state != .ready else { return }
        state = .downloading
        Task {
            do {
                try await ParakeetService.shared.prepare()
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
