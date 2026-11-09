import AVFoundation
import Foundation

/// "Check who spoke": right after a call, each voice on the other side with
/// its name (or none), a few things they said, and a 15-second clip, so a wrong or
/// missing name can be fixed before the summary is written. Pure data; the
/// building is unit tested.
struct SpeakerCheck: Equatable {
    enum Status: Equatable {
        /// You named them during the call.
        case namedLive
        /// Warble recognised them clearly.
        case recognised
        /// Warble only guessed ("Jordan?").
        case guess
        /// Two different-sounding voices both got this name.
        case shared
        /// Nobody named them.
        case unnamed

        var needsCheck: Bool { self == .guess || self == .shared || self == .unnamed }
    }

    struct Row: Identifiable, Equatable {
        /// The voice's id in `voices`.
        var id: String
        /// The name it has now (without any "?").
        var name: String?
        /// The name it had when the call was saved.
        var originalName: String?
        var status: Status
        /// "voice 1", "voice 2" when the name is shared.
        var part: Int? = nil
        var talk: TimeInterval
        var quote: String
        /// When in the call to play from (seconds since the call started).
        var clip: ClosedRange<TimeInterval>?
        /// One-tap names for an unnamed voice or a guess.
        var suggestions: [NameSuggestion] = []
        /// You tapped to confirm or change this row, so Warble may learn it.
        var confirmed = false

        var needsCheck: Bool { status.needsCheck && !confirmed }
    }

    var rows: [Row]
    /// The saved note.
    var url: URL
    var started: Date
    /// The other side's recording, and where it starts in the call.
    var othersFile: URL?
    var othersOffset: TimeInterval
    /// Which voice spoke when, as the transcript was labeled.
    var voices: [VoiceSegment]
    /// How each voice sounds, for learning names you confirm.
    var prints: [String: [Float]]
    /// Voice recordings Warble learned when the call was saved, by voice, so
    /// a name you correct can be taken back out.
    var learnedAtSave: [String: UUID]
    /// What Warble learned from names given live on this call, by name (lowercased).
    var learnedLive: [String: [UUID]] = [:]
    /// Every voice's name as the call was saved (including voices too short
    /// to list), so "Speaker N" numbers stay put as you fix names.
    var savedNames: [String: String] = [:]
    /// Done or Later pressed.
    var finished = false

    var toCheck: Int { rows.filter(\.needsCheck).count }


    /// Voices quieter than this aren't listed (usually noise or a cough).
    static let minimumTalk: TimeInterval = 3
    /// The longest a clip plays: long enough to know someone by.
    static let clipLength: TimeInterval = 15

    /// The rows, in the order people first spoke. `names` may hold guesses
    /// marked with a trailing "?". Two voices with one name count as
    /// "shared" only when they sound clearly different.
    static func rows(voices: [VoiceSegment], names: [String: String], namedLive: Set<String>,
                     prints: [String: [Float]], quote: (String) -> String) -> [Row] {
        let talk = SpeakerAssigner.talkTime(voices)
        var order: [String] = []
        for segment in voices where !order.contains(segment.speakerID) && (talk[segment.speakerID] ?? 0) >= minimumTalk {
            order.append(segment.speakerID)
        }
        let shared = sharedNames(order: order, names: names, prints: prints)
        var parts: [String: Int] = [:]
        return order.map { id in
            let raw = names[id]
            let isGuess = raw?.hasSuffix("?") ?? false
            let name = raw.map { isGuess ? String($0.dropLast()) : $0 }
            let status: Status
            var part: Int?
            if let name, shared.contains(name.lowercased()) {
                status = .shared
                parts[name.lowercased(), default: 0] += 1
                part = parts[name.lowercased()]
            } else if name == nil {
                status = .unnamed
            } else if isGuess {
                status = .guess
            } else if namedLive.contains(name!.lowercased()) {
                status = .namedLive
            } else {
                status = .recognised
            }
            return Row(id: id, name: name, originalName: name, status: status, part: part, talk: talk[id] ?? 0,
                       quote: quote(id), clip: clip(for: id, in: voices))
        }
    }

    /// Where to play a voice from: its longest stretch, carried on through
    /// what it said straight after (until someone else talks or there's a
    /// pause), up to `clipLength`.
    static func clip(for id: String, in voices: [VoiceSegment]) -> ClosedRange<TimeInterval>? {
        let ordered = voices.sorted { $0.start < $1.start }
        guard let first = ordered.indices.filter({ ordered[$0].speakerID == id })
            .max(by: { ordered[$0].end - ordered[$0].start < ordered[$1].end - ordered[$1].start }) else { return nil }
        let start = ordered[first].start
        var end = min(ordered[first].end, start + clipLength)
        for next in ordered[(first + 1)...] where end < start + clipLength {
            guard next.speakerID == id, next.start - end <= 1.5 else { break }
            end = min(max(end, next.end), start + clipLength)
        }
        return start...end
    }

    /// Names (lowercased) that two clearly different voices share.
    static func sharedNames(order: [String], names: [String: String], prints: [String: [Float]]) -> Set<String> {
        var groups: [String: [String]] = [:]
        for id in order {
            guard let raw = names[id] else { continue }
            let name = raw.hasSuffix("?") ? String(raw.dropLast()) : raw
            groups[name.lowercased(), default: []].append(id)
        }
        var shared = Set<String>()
        for (name, ids) in groups where ids.count > 1 {
            let found = ids.compactMap { prints[$0] }
            for i in found.indices {
                for j in found.indices where j > i && VoiceMatcher.distance(found[i], found[j]) > VoiceMatcher.tentativeDistance {
                    shared.insert(name)
                }
            }
        }
        return shared
    }

    /// Relabels the transcript's lines from the other side by the check's
    /// names. Lines from you are left alone.
    func relabel(_ transcript: inout CallTranscript, unnamed: (String) -> String) {
        let names = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for index in transcript.segments.indices where transcript.segments[index].speaker != CallRecorder.meLabel {
            let range = CallTranscript.spokenRange(of: transcript.segments[index])
            guard let id = SpeakerAssigner.speaker(for: range, in: voices), let entry = names[id] else { continue }
            transcript.segments[index].speaker = entry ?? unnamed(id)
        }
    }
}

/// Plays a few seconds of one voice from a call's recording.
@MainActor
final class ClipPlayer: ObservableObject {
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(_ rowID: String, file: URL, from start: TimeInterval, length: TimeInterval) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: file) else { return }
        player.currentTime = max(0, min(start, player.duration - 0.5))
        guard player.play() else { return }
        self.player = player
        playing = rowID
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}
