import SwiftUI

/// "Check who spoke" (see SpeakerCheck): shown on the saved-call card, and
/// from the Calls page. One row per voice: a clip, a line they said, and the
/// fix choices. Only rows you tap are learned.
struct SpeakerCheckView: View {
    @EnvironmentObject private var calls: CallController
    @ObservedObject var clips: ClipPlayer
    let check: SpeakerCheck
    @State private var typing: String?
    @State private var typed = ""
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Check who spoke").font(.subheadline.weight(.semibold))
                Spacer()
                if check.toCheck > 0 {
                    Text("\(check.toCheck) to check")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CallPanelColor.amber)
                }
            }
            .padding(.bottom, 4)
            // A long call's list scrolls rather than pushing Done off the screen.
            if check.rows.count > 3 {
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .frame(height: min(max(rowsHeight, 120), 440))
            } else {
                rows
            }
            HStack {
                Button("Later") { calls.postponeCheck() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Keep this for the Calls page; nothing more is learned now")
                Spacer()
                Button(check.toCheck > 0 ? "Done · \(check.toCheck) left unsure" : "Done") { calls.finishCheck() }
                    .buttonStyle(.borderedProminent)
                    .help("Learn the voices you confirmed. Rows you left alone stay unsure and aren't learned.")
            }
            .padding(.top, 10)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(check.rows.enumerated()), id: \.element.id) { index, row in
                if row.status == .shared, row.part == 1 {
                    Text("Two voices called \(row.name ?? "")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CallPanelColor.amber)
                        .padding(.top, 8)
                }
                rowView(row)
                if index < check.rows.count - 1 { Divider() }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SpeakerCheck.Row) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                avatar(row)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title(row)).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(status(row))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(row.needsCheck ? CallPanelColor.amber : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if row.clip != nil, check.othersFile != nil {
                    Button { calls.playClip(row.id) } label: {
                        Image(systemName: clips.playing == row.id ? "stop.fill" : "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(WarbleColor.green)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(WarbleColor.surface))
                            .overlay(Circle().strokeBorder(WarbleColor.line, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Play this voice")
                }
            }
            // What they said, at full width so there's enough to know them by.
            if !row.quote.isEmpty {
                Text("\u{201C}\(row.quote)\u{201D}")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
            fixes(row)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func fixes(_ row: SpeakerCheck.Row) -> some View {
        if typing == row.id {
            HStack(spacing: 6) {
                TextField("Their name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(row) }
                    .onExitCommand { typing = nil }
                Button("OK") { submit(row) }
            }
            .padding(.leading, 40)
        } else if row.confirmed {
            EmptyView()
        } else if row.status.needsCheck {
            FlowLayout(spacing: 6) {
                if let name = row.name {
                    fixButton("This is \(name)") { calls.checkName(row.id, as: name) }
                }
                ForEach(row.suggestions.filter { $0.name.caseInsensitiveCompare(row.name ?? "") != .orderedSame }) { suggestion in
                    fixButton(suggestion.name, detail: suggestion.reason) { calls.checkName(row.id, as: suggestion.name) }
                }
                sameAsMenu(row)
                fixButton(row.name == nil ? "Type a name" : "Someone else…") { startTyping(row) }
            }
            .padding(.leading, 40)
        } else {
            HStack(spacing: 6) {
                fixButton("Not \(row.name ?? "them")?") { startTyping(row) }
                sameAsMenu(row)
            }
            .padding(.leading, 40)
        }
    }

    @ViewBuilder
    private func sameAsMenu(_ row: SpeakerCheck.Row) -> some View {
        let others = check.rows.filter { $0.id != row.id && $0.name != nil && $0.name != row.name }
        if !others.isEmpty {
            Menu {
                ForEach(others) { other in
                    Button(other.name ?? "") { calls.checkSame(row.id, as: other.id) }
                }
            } label: {
                Text("Same as…").font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func fixButton(_ title: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(WarbleColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WarbleColor.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func avatar(_ row: SpeakerCheck.Row) -> some View {
        let warn = row.status == .unnamed || row.status == .shared
        let text = row.name.map { name in
            let parts = name.split(separator: " ")
            let letters = parts.count >= 2 ? String(parts[0].prefix(1)) + String(parts[parts.count - 1].prefix(1))
                : String(name.prefix(2))
            return letters.uppercased() + (row.part.map(String.init) ?? "")
        } ?? "?"
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(warn ? CallPanelColor.amber : .primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(warn ? Color.clear : WarbleColor.surface))
            .overlay(Circle().strokeBorder(warn ? CallPanelColor.amber.opacity(0.6) : WarbleColor.line,
                                           style: StrokeStyle(lineWidth: 1, dash: warn ? [3, 2] : [])))
    }

    private func title(_ row: SpeakerCheck.Row) -> String {
        guard let name = row.name else { return "Unnamed voice" }
        if let part = row.part, row.status == .shared { return "\(name) · voice \(part)" }
        return name
    }

    private func status(_ row: SpeakerCheck.Row) -> String {
        let minutes = row.talk >= 60 ? "\(Int((row.talk / 60).rounded())) min" : "\(Int(row.talk)) s"
        if row.confirmed { return "confirmed" }
        switch row.status {
        case .namedLive: return "named live"
        case .recognised: return "known voice"
        case .guess: return "not sure · \(minutes)"
        case .shared: return minutes
        case .unnamed: return "unnamed · \(minutes)"
        }
    }

    private func startTyping(_ row: SpeakerCheck.Row) {
        typed = ""
        typing = row.id
    }

    private func submit(_ row: SpeakerCheck.Row) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typing = nil
        guard !name.isEmpty else { return }
        calls.checkName(row.id, as: name)
    }
}
