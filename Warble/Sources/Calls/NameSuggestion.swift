import Foundation

/// A one-tap answer to "Who's this?".
struct NameSuggestion: Equatable, Identifiable {
    var name: String
    /// Why Warble suggests it, e.g. "heard “Matt”, sounds like them".
    var reason: String
    /// Set for "Same person as AJ": the voice on this call it joins.
    var joins: String? = nil

    var id: String { (joins ?? "") + "|" + name.lowercased() }
    /// What the button says.
    var title: String { joins == nil ? name : "Same person as \(name)" }

    /// The most suggestions shown.
    static let limit = 3

    /// Builds the suggestions, best first. Pure, unit tested.
    /// - A name heard said comes first. If someone on file sounds like the
    ///   voice and has that name (or that first name), the two are one
    ///   suggestion with their full name, so "Matt" and "Matt Kern" don't
    ///   become two people.
    /// - Then the people on file the voice sounds most like.
    /// - Last, and only when the voices are close, someone already on this
    ///   call ("Same person as AJ"): joining two people by mistake is the
    ///   worst error, so it's never the first thing offered when anything
    ///   else is.
    static func build(hint: String?, candidates: [(name: String, distance: Float)],
                      onCall: [(name: String, voiceID: String, distance: Float)]) -> [NameSuggestion] {
        var list: [NameSuggestion] = []
        var used = Set<String>()
        if let hint = hint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            let wanted = hint.lowercased()
            if let match = candidates.first(where: { $0.name.lowercased() == wanted || firstName($0.name) == wanted }) {
                list.append(NameSuggestion(name: match.name, reason: "heard “\(hint)”, sounds like them"))
            } else {
                list.append(NameSuggestion(name: hint, reason: "heard “\(hint)”"))
            }
            used.insert(list[0].name.lowercased())
        }
        for candidate in candidates where used.insert(candidate.name.lowercased()).inserted {
            list.append(NameSuggestion(name: candidate.name, reason: "sounds like them"))
        }
        list = Array(list.prefix(limit))
        for person in onCall.sorted(by: { $0.distance < $1.distance }) where list.count < limit {
            guard used.insert(person.name.lowercased()).inserted else { continue }
            list.append(NameSuggestion(name: person.name, reason: "similar voice, on this call", joins: person.voiceID))
        }
        return list
    }

    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map { $0.lowercased() } ?? name.lowercased()
    }
}
