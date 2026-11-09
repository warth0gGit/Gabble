import Foundation

/// Keeps apart people the voice engine lumped together. The engine decides
/// once whether a voice is new; on a Teams call it sometimes decides two or
/// three people are one (AJ and Matt both taken for Jordan), and then never
/// asks about them. So every stretch of speech is also checked here against
/// how that voice sounded when it was first heard (a fixed fingerprint that,
/// unlike the engine's, doesn't drift towards whoever else gets lumped in).
/// Speech that clearly sounds like someone else for a few seconds in a row
/// becomes a voice of its own, which Warble then matches or asks about.
/// The other way round, the engine sometimes decides someone already heard
/// is new (one ten-second print came out a little different), and then they
/// show up as a stranger; so a new voice from the engine that clearly sounds
/// like someone heard earlier is taken to be them.
/// Pure, unit tested.
struct VoiceSplitter {
    /// Only a stretch at least this long is judged; shorter ones are too noisy.
    static let judgeSeconds: TimeInterval = 1.5
    /// A voice's fingerprint is built from its first this-many seconds of speech, then fixed.
    static let anchorSeconds: TimeInterval = 8
    /// Within this (cosine distance) of a voice's fingerprint, it's that voice.
    static let sameDistance: Float = 0.5
    /// This much speech in a row that sounds like nobody here makes a new voice.
    static let splitSeconds: TimeInterval = 4
    /// "The person talking now": their speech in the last this-many seconds.
    static let recentSeconds: TimeInterval = 12
    /// A new voice from the engine whose first clear stretch is within this
    /// of someone already heard (their fixed fingerprint), and clearly nearer
    /// them than anyone else (by `sameAsEarlierMargin`), is that person.
    /// The engine judges a new voice from one ten-second print against a
    /// print of its own that drifts; Warble's fingerprints are steadier. In
    /// the replay of 12 recorded calls this cut the times someone already
    /// heard came up as a new voice by about a third (a fifth to three
    /// quarters, line by line), without putting more speech under a wrong name.
    static let sameAsEarlierDistance: Float = 0.45
    static let sameAsEarlierMargin: Float = 0.1

    /// Every stretch heard, with the voice Warble thinks it is.
    private(set) var segments: [VoiceSegment] = []
    /// The engine's voice for each stretch, in step with `segments`.
    private var engineIDs: [String] = []

    private struct Anchor {
        var sum: [Float]
        var seconds: TimeInterval
        var isFixed: Bool { seconds >= VoiceSplitter.anchorSeconds }

        init(_ embedding: [Float], seconds: TimeInterval) {
            sum = VoiceSplitter.unit(embedding).map { $0 * Float(seconds) }
            self.seconds = seconds
        }

        mutating func add(_ embedding: [Float], seconds more: TimeInterval) {
            let unit = VoiceSplitter.unit(embedding)
            guard unit.count == sum.count else { return }
            for i in sum.indices { sum[i] += unit[i] * Float(more) }
            seconds += more
        }
    }

    private var anchors: [String: Anchor] = [:]
    /// The voices Warble has found inside each of the engine's voices (the engine's own ID first).
    private var family: [String: [String]] = [:]
    /// Doubtful stretches in a row, per engine voice (indexes into `segments`).
    private var doubt: [String: [Int]] = [:]
    /// The voice each engine voice was last clearly heard as.
    private var lastVoice: [String: String] = [:]
    private var splits = 0
    /// Each engine voice, once its first clear stretch is in: itself, or the
    /// engine voice of the person heard earlier that it turned out to be.
    private var sameAs: [String: String] = [:]

    /// Adds what the engine heard, checking each stretch.
    mutating func add(_ new: [VoiceSegment]) {
        for segment in new { add(segment) }
    }

    private mutating func add(_ segment: VoiceSegment) {
        let engine = engineVoice(for: segment)
        if family[engine] == nil { family[engine] = [engine] }
        let seconds = segment.end - segment.start
        let current = lastVoice[engine] ?? engine

        guard !segment.embedding.isEmpty, seconds >= Self.judgeSeconds else {
            append(segment, as: current, engine: engine)
            return
        }
        let ranked = (family[engine] ?? [engine])
            .compactMap { id in anchors[id].map { (id: id, distance: Self.distance(segment.embedding, $0.sum)) } }
            .sorted { $0.distance < $1.distance }

        guard let best = ranked.first else {
            // The first clear speech from this voice: it starts the fingerprint.
            anchors[engine] = Anchor(segment.embedding, seconds: seconds)
            append(segment, as: engine, engine: engine)
            lastVoice[engine] = engine
            return
        }
        if best.distance <= Self.sameDistance {
            append(segment, as: best.id, engine: engine)
            if anchors[best.id]?.isFixed == false { anchors[best.id]?.add(segment.embedding, seconds: seconds) }
            lastVoice[engine] = best.id
            doubt[engine] = []
            return
        }

        // Sounds like nobody in this voice so far: shown as before for now.
        append(segment, as: current, engine: engine)
        doubt[engine, default: []].append(segments.count - 1)
        let run = doubt[engine] ?? []
        let runSeconds = run.reduce(0) { $0 + segments[$1].end - segments[$1].start }
        guard runSeconds >= Self.splitSeconds else { return }

        var together: Anchor?
        for index in run {
            let s = segments[index]
            if together == nil { together = Anchor(s.embedding, seconds: s.end - s.start) }
            else { together?.add(s.embedding, seconds: s.end - s.start) }
        }
        guard let together else { return }
        let nearest = (family[engine] ?? [])
            .compactMap { id in anchors[id].map { (id: id, distance: Self.distance(together.sum, $0.sum)) } }
            .min { $0.distance < $1.distance }
        let voice: String
        if let nearest, nearest.distance <= Self.sameDistance {
            voice = nearest.id          // only noise after all
        } else {
            splits += 1
            voice = "\(engine)#\(splits + 1)"
            anchors[voice] = together
            family[engine, default: [engine]].append(voice)
        }
        for index in run { segments[index].speakerID = voice }
        lastVoice[engine] = voice
        doubt[engine] = []
    }

    /// The engine voice this stretch is checked under: the engine's own, or,
    /// for a voice the engine has just started, the person heard earlier it
    /// clearly sounds like. Decided once, on the voice's first clear stretch.
    private mutating func engineVoice(for segment: VoiceSegment) -> String {
        let id = segment.speakerID
        if let decided = sameAs[id] { return decided }
        // Until its first clear stretch it shows as a voice of its own.
        guard !segment.embedding.isEmpty, segment.end - segment.start >= Self.judgeSeconds else { return id }
        // Already on show by then (2 s of short bits): left as it is, so a
        // voice on screen, or being asked about, never just disappears.
        let shown = segments.indices.filter { engineIDs[$0] == id }
            .reduce(0) { $0 + segments[$1].end - segments[$1].start }
        guard shown < 2, let earlier = voiceHeardEarlier(soundingLike: segment.embedding),
              let owner = family.first(where: { $0.value.contains(earlier) })?.key, owner != id else {
            sameAs[id] = id
            return id
        }
        sameAs[id] = owner
        // Its first few short stretches were that person too.
        for index in segments.indices where engineIDs[index] == id {
            segments[index].speakerID = earlier
            engineIDs[index] = owner
        }
        family[id] = nil
        lastVoice[id] = nil
        doubt[id] = nil
        return owner
    }

    /// The voice heard so far that `embedding` clearly sounds like, if any.
    private func voiceHeardEarlier(soundingLike embedding: [Float]) -> String? {
        let ranked = anchors.filter { $0.value.seconds >= 2 }
            .map { (id: $0.key, distance: Self.distance(embedding, $0.value.sum)) }
            .sorted { $0.distance < $1.distance }
        guard let best = ranked.first, best.distance <= Self.sameAsEarlierDistance else { return nil }
        if ranked.count > 1, ranked[1].distance - best.distance < Self.sameAsEarlierMargin { return nil }
        return best.id
    }

    private mutating func append(_ segment: VoiceSegment, as voice: String, engine: String) {
        var s = segment
        s.speakerID = voice
        segments.append(s)
        engineIDs.append(engine)
    }

    /// You said the person talking now, shown as `voice`, is someone else:
    /// their recent speech becomes a voice of its own, with its own
    /// fingerprint, so it's told apart from now on. Nil if there's too little
    /// to go on (then the whole voice is renamed instead).
    mutating func splitRecent(of voice: String) -> String? {
        guard let last = segments.lastIndex(where: { $0.speakerID == voice }) else { return nil }
        let engine = engineIDs[last]
        let old = anchors[voice]
        // Their turn: back from the latest stretch, until someone else spoke,
        // a pause, 12 seconds, or a stretch that sounds more like the old voice.
        var recent: [Int] = [last]
        var run: Anchor? = segments[last].embedding.isEmpty ? nil
            : Anchor(segments[last].embedding, seconds: max(0.5, segments[last].end - segments[last].start))
        var earliest = segments[last].start
        var index = last - 1
        while index >= 0 {
            let s = segments[index]
            defer { index -= 1 }
            if s.speakerID != voice {
                if s.end >= earliest - 1.5 { break }   // someone else spoke just before
                continue
            }
            if earliest - s.end > 1.5 || segments[last].end - s.start > Self.recentSeconds { break }
            if !s.embedding.isEmpty, let run, let old,
               Self.distance(s.embedding, old.sum) < Self.distance(s.embedding, run.sum) {
                break   // that's the person this voice was before
            }
            recent.append(index)
            earliest = min(earliest, s.start)
            if !s.embedding.isEmpty {
                let seconds = max(0.5, s.end - s.start)
                if run == nil { run = Anchor(s.embedding, seconds: seconds) } else { run?.add(s.embedding, seconds: seconds) }
            }
        }
        guard let run else { return nil }
        splits += 1
        let split = "\(engine)#\(splits + 1)"
        anchors[split] = run
        family[engine, default: [engine]].append(split)
        for index in recent { segments[index].speakerID = split }
        lastVoice[engine] = split
        doubt[engine] = []
        return split
    }

    /// How a voice sounded on this call, once Warble has heard enough of it.
    func fingerprint(for voice: String) -> [Float]? {
        guard let anchor = anchors[voice], anchor.seconds >= 2 else { return nil }
        return Self.unit(anchor.sum)
    }

    /// How a voice sounded over the whole call (every clear stretch of it,
    /// weighted by length), once it has said at least `seconds`. Steadier
    /// than the first few seconds, so it's what Warble learns for next time.
    func callPrint(for voice: String, atLeast seconds: TimeInterval = 15) -> [Float]? {
        var sum: [Float] = []
        var total: TimeInterval = 0
        for s in segments where s.speakerID == voice && !s.embedding.isEmpty {
            let length = s.end - s.start
            guard length >= Self.judgeSeconds else { continue }
            let unit = Self.unit(s.embedding)
            if sum.isEmpty { sum = [Float](repeating: 0, count: unit.count) }
            guard unit.count == sum.count else { continue }
            for i in sum.indices { sum[i] += unit[i] * Float(length) }
            total += length
        }
        guard total >= seconds else { return nil }
        return Self.unit(sum)
    }

    /// How a person sounded over the whole call, from the live voices
    /// under their name (`names`: voice to name): the one that said most and
    /// stayed one person all call (its whole-call print still close to how
    /// it first sounded). Nil if none did.
    func callPrint(of name: String, names: [String: String]) -> [Float]? {
        let talk = SpeakerAssigner.talkTime(segments)
        let theirs = names.filter { $0.value.caseInsensitiveCompare(name) == .orderedSame }.map(\.key)
            .sorted { (talk[$0] ?? 0) > (talk[$1] ?? 0) }
        for voice in theirs {
            guard let print = callPrint(for: voice) else { continue }
            if let first = fingerprint(for: voice), Self.distance(print, first) > Self.steadyDistance { continue }
            return print
        }
        return nil
    }

    /// A voice whose whole-call print is further than this from its first
    /// seconds has had someone else lumped in, and isn't learned from.
    static let steadyDistance: Float = 0.4

    // MARK: - Maths

    static func distance(_ a: [Float], _ b: [Float]) -> Float { VoiceMatcher.distance(a, b) }

    static func unit(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

/// A likely name for a new voice from what was said around it: "Thanks,
/// Matt", "AJ, what do you think?" just before they spoke, or "It's Matt"
/// from the voice itself. Only ever offered as a suggestion. Pure, unit tested.
enum NameHints {
    private static let name = #"([A-Z][A-Za-z'\-]+)"#
    /// Someone introducing themselves.
    private static let ownPatterns = [
        #"(?i:\b(?:it['’]s|it is|this is|i['’]m|i am|my name is|my name['’]s))\s+"# + name + #"\b"#,
        #"\b"# + name + #"\s+here\b"#,
    ]
    /// Someone being spoken to just before they talk.
    private static let addressedPatterns = [
        #"(?i:\b(?:thanks|thank you|cheers|over to you|go ahead|hi|hey|hello|morning|welcome|you there))[,.]?\s+"# + name + #"\b"#,
        #"\b"# + name + #",\s+(?i:what|can|could|do|did|would|any|are|is|how|have|you)\b"#,
    ]
    private static let notNames: Set<String> = [
        "I", "Okay", "Ok", "So", "Yeah", "Yes", "No", "Everyone", "Everybody", "Guys", "All", "Team", "There",
        "Good", "Great", "Sorry", "Just", "Well", "Now", "Then", "And", "But", "The", "This", "That", "Thanks",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Teams", "Zoom", "Here",
        "Right", "Sure", "Cool", "Perfect", "Lovely", "Hi", "Hello", "Hey", "Me", "Folks", "Both", "Again",
    ]

    /// - Parameters:
    ///   - own: what the new voice itself said first.
    ///   - before: what was said just before the voice started.
    ///   - taken: names already used by someone else on the call.
    static func guess(own: [String], before: [String], taken: [String]) -> String? {
        let excluded = Set(taken.map { $0.lowercased() })
        func first(_ patterns: [String], in texts: [String], latestFirst: Bool) -> String? {
            for text in latestFirst ? texts.reversed() : texts {
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for match in latestFirst ? matches.reversed() : matches {
                        guard let range = Range(match.range(at: 1), in: text) else { continue }
                        let word = String(text[range])
                        if word.count >= 2, !notNames.contains(word), !excluded.contains(word.lowercased()) {
                            return word
                        }
                    }
                }
            }
            return nil
        }
        return first(ownPatterns, in: own, latestFirst: false) ?? first(addressedPatterns, in: before, latestFirst: true)
    }
}
