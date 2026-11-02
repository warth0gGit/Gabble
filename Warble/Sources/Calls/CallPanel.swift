import AppKit
import SwiftUI

/// A small floating card in the top-right corner for calls: "Transcribe this
/// call?", the live card while a call is transcribed (who's talking, and
/// "Who's this?" for a new voice), the end-of-call steps, and "Transcript
/// saved". It can be clicked without taking focus away from the call, dragged
/// somewhere else (Warble remembers where), and shrunk to a small pill.
@MainActor
final class CallPanel {
    private let panel: NSPanel
    private let relay = SizeRelay()
    private var size = CGSize(width: 340, height: 120)
    private var placing = false
    private var moveObserver: NSObjectProtocol?

    private static let rightKey = "callPanelRightInset"
    private static let topKey = "callPanelTopInset"

    /// A borderless panel that can still take typing (for "Who's this?").
    private final class TypingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(controller: CallController) {
        panel = TypingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CallPanelView(sizeRelay: relay).environmentObject(controller))
        // Warble sizes the panel to the card itself, pinned to its corner.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        relay.onChange = { [weak self] newSize in self?.resize(to: newSize) }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
    }

    func show() {
        place()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func resize(to newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1, newSize != size else { return }
        size = newSize
        // Move the window after SwiftUI finishes its layout pass, never during it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.place()
            }
        }
    }

    /// Keeps the card's top-right corner where it was (the screen's top-right
    /// corner unless you've dragged it), so it grows down and to the left.
    private func place() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let defaults = UserDefaults.standard
        let right = defaults.object(forKey: Self.rightKey) as? Double ?? 16
        let top = defaults.object(forKey: Self.topKey) as? Double ?? 12
        let x = min(max(frame.minX, frame.maxX - right - size.width), frame.maxX - size.width)
        let y = min(max(frame.minY, frame.maxY - top - size.height), frame.maxY - size.height)
        placing = true
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        placing = false
    }

    /// Remembers where you dragged the card.
    private func rememberPosition() {
        guard !placing, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        UserDefaults.standard.set(Double(frame.maxX - panel.frame.maxX), forKey: Self.rightKey)
        UserDefaults.standard.set(Double(frame.maxY - panel.frame.maxY), forKey: Self.topKey)
    }
}

/// Passes the card's size from SwiftUI to the panel.
@MainActor
final class SizeRelay {
    var onChange: ((CGSize) -> Void)?
}

enum CallPanelColor {
    static let amber = Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x4B / 255)
}

struct CallPanelView: View {
    @EnvironmentObject private var calls: CallController
    let sizeRelay: SizeRelay
    @State private var whoName = ""
    @State private var newFolder = ""

    var body: some View {
        Group {
            if showsMiniPill {
                miniPill.fixedSize()
            } else {
                card
                    .frame(width: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            sizeRelay.onChange?(size)
        }
    }

    private var showsMiniPill: Bool {
        calls.isRecording && calls.panelMinimized
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WarbleColor.green.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if let error = calls.lastError, calls.state == .idle {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { calls.dismissError() }
        } else {
            switch calls.state {
            case .asking(let appName):
                HStack(spacing: 8) {
                    WaveformRibbon(level: 0, isActive: false, strands: 5).frame(width: 34, height: 18)
                    Text("Transcribe this \(shortName(appName)) call?").font(.headline)
                }
                Text("Warble will transcribe both sides on this Mac and save it to your Calls folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Not now") { calls.declinePrompt() }
                    Spacer()
                    Button("Transcribe") { calls.acceptPrompt() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .recording(let appName):
                liveCard(appName: appName)
            case .saving:
                savingSteps
            case .saved(let url):
                savedCard(url: url)
            case .filing:
                savedHeader
                filingChoice
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - During the call

    @ViewBuilder
    private func liveCard(appName: String) -> some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text("Transcribing \(shortName(appName)) call")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            ElapsedTime(since: calls.recordingStarted)
            Button {
                calls.panelMinimized = true
            } label: {
                Image(systemName: "minus").font(.caption.weight(.bold)).frame(width: 22, height: 22)
                    // Without this only the thin dash itself takes the click, and a
                    // click beside it drags the card instead.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Shrink to a small pill")
            Button {
                calls.stopRecording()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold))
                    Text("Stop").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(.primary)
                .background(Capsule().fill(WarbleColor.surface))
                .overlay(Capsule().strokeBorder(WarbleColor.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop transcribing and save the transcript")
        }
        FlowLayout(spacing: 6) {
            ForEach(calls.liveSpeakers) { SpeakerChip(speaker: $0) }
        }
        if let asking = calls.askingWho {
            whosThis(sample: asking.sample)
        }
    }

    @ViewBuilder
    private func whosThis(sample: String) -> some View {
        Divider()
        HStack {
            Text("Who's this?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CallPanelColor.amber)
            Spacer()
            Button(action: skipVoice) {
                Text("Skip").padding(.horizontal, 4).padding(.vertical, 2).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !sample.isEmpty {
            Text("\u{201C}\(sample)\u{201D}")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
        }
        TextField("Type a name, or press Esc to skip", text: $whoName)
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveName)
            .onExitCommand(perform: skipVoice)
    }

    private var miniPill: some View {
        Button {
            calls.panelMinimized = false
        } label: {
            HStack(spacing: 8) {
                PulsingDot()
                ElapsedTime(since: calls.recordingStarted)
                if calls.askingWho != nil {
                    Text("Who's this?")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CallPanelColor.amber)
                } else if let talking = calls.liveSpeakers.first(where: \.isSpeaking) {
                    Text(talking.name)
                        .font(.caption)
                        .foregroundStyle(WarbleColor.glow)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(WarbleColor.green.opacity(0.25), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the full card")
    }

    // MARK: - After the call

    private struct Step: Identifiable {
        var id: String { title }
        var title: String
        var step: CallController.SavingStep?
    }

    private var steps: [Step] {
        var list: [Step] = []
        if calls.savingRereads { list.append(Step(title: "Re-reading the recording for accuracy", step: .rereading)) }
        list.append(Step(title: "Tidying up", step: .tidying))
        list.append(Step(title: "Saving to Obsidian", step: .saving))
        if calls.summaryWillFollow { list.append(Step(title: "Summary and actions (added in a minute or two)", step: nil)) }
        return list
    }

    @ViewBuilder
    private var savingSteps: some View {
        Text("Call ended. Saving the transcript").font(.headline)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(steps) { item in
                HStack(spacing: 8) {
                    stepMark(for: item.step)
                        .frame(width: 14, height: 14)
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(item.step.map { isWaiting($0) } ?? true ? .secondary : .primary)
                }
            }
        }
    }

    @ViewBuilder
    private func stepMark(for step: CallController.SavingStep?) -> some View {
        if let step {
            if isDone(step) {
                ZStack {
                    Circle().fill(WarbleColor.green)
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.black)
                }
            } else if step == calls.savingStep {
                ProgressView().controlSize(.mini)
            } else {
                Circle().strokeBorder(WarbleColor.line, lineWidth: 1.5)
            }
        } else {
            // The summary comes later, after the card has gone.
            Circle().strokeBorder(WarbleColor.line, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        }
    }

    private func isDone(_ step: CallController.SavingStep) -> Bool {
        guard let current = calls.savingStep else { return true }
        return step < current
    }

    private func isWaiting(_ step: CallController.SavingStep) -> Bool {
        guard let current = calls.savingStep else { return false }
        return step > current
    }

    @ViewBuilder
    private var savedHeader: some View {
        Label("Transcript saved", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(WarbleColor.green)
        if let stats = calls.savedStats {
            HStack(spacing: 12) {
                stat(stats.minutes, "min")
                stat(stats.speakers, stats.speakers == 1 ? "speaker" : "speakers")
                stat(stats.words, stats.words == 1 ? "word" : "words")
            }
        }
    }

    private func stat(_ value: Int, _ unit: String) -> some View {
        HStack(spacing: 3) {
            Text(value.formatted()).fontWeight(.semibold).foregroundStyle(.primary)
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private func savedCard(url: URL) -> some View {
        savedHeader
        Text(url.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if let note = calls.filedNote {
            Text(note + (calls.savedStats?.summaryPending == true ? " Summary on its way." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Change folder") { calls.changeFolder() }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
                .buttonStyle(.borderedProminent)
        }
    }

    /// "Where should this call go?": Warble's best guesses, a box for a new
    /// folder, or leave it in Unfiled. The choice is remembered for next time.
    @ViewBuilder
    private var filingChoice: some View {
        Divider()
        Label("Where should this call go?", systemImage: "folder")
            .font(.headline)
        if let title = calls.transcript?.meeting?.title, !title.isEmpty {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        ForEach(calls.filingSuggestions, id: \.folder) { suggestion in
            Button {
                calls.file(into: suggestion.folder)
            } label: {
                HStack {
                    Image(systemName: suggestion.reason == "new folder" ? "folder.badge.plus" : "folder.fill")
                    Text(suggestion.folder).lineLimit(1)
                    Spacer()
                    Text(suggestion.reason).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        HStack {
            TextField("New folder, e.g. 1-1s/Sarah", text: $newFolder)
                .textFieldStyle(.roundedBorder)
                .onSubmit(fileInNewFolder)
            Button("File", action: fileInNewFolder)
                .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Button("Leave in Unfiled") { calls.leaveUnfiled() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func fileInNewFolder() {
        let folder = newFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { return }
        calls.file(into: folder)
        newFolder = ""
    }

    private func saveName() {
        calls.nameVoice(whoName)
        whoName = ""
    }

    private func skipVoice() {
        whoName = ""
        calls.skipVoice()
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
    }
}

// MARK: - Pieces

/// A person's chip. It lights up green while they're talking; a voice Warble
/// is asking about is amber and dashed.
struct SpeakerChip: View {
    var speaker: CallController.LiveSpeaker

    var body: some View {
        HStack(spacing: 5) {
            SpeakingBars(active: speaker.isSpeaking)
            Text(speaker.name).font(.caption).lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .foregroundStyle(textColor)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: speaker.isNew ? [3, 2] : [])))
        .animation(.easeOut(duration: 0.2), value: speaker.isSpeaking)
    }

    private var accent: Color { speaker.isNew ? CallPanelColor.amber : WarbleColor.glow }
    private var textColor: Color { speaker.isSpeaking || speaker.isNew ? accent : WarbleColor.idle }
    private var fill: Color {
        speaker.isSpeaking ? (speaker.isNew ? CallPanelColor.amber : WarbleColor.green).opacity(0.12) : WarbleColor.surface
    }
    private var border: Color {
        if speaker.isNew { return CallPanelColor.amber.opacity(0.6) }
        return speaker.isSpeaking ? WarbleColor.green.opacity(0.6) : WarbleColor.line
    }
}

/// Three little bars that move while someone talks.
struct SpeakingBars: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .frame(width: 2, height: height(i, t))
                }
            }
            .frame(height: 12)
        }
        .opacity(active ? 1 : 0.5)
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        guard active else { return 3 }
        if reduceMotion { return 8 }
        return 3 + 9 * abs(sin(t * 7 + Double(i) * 0.9))
    }
}

/// The green "transcribing" light.
struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 1 : (1 + cos(context.date.timeIntervalSinceReferenceDate * .pi)) / 2
            Circle()
                .fill(WarbleColor.green)
                .frame(width: 8, height: 8)
                .opacity(0.35 + 0.65 * phase)
                .shadow(color: WarbleColor.green.opacity(phase), radius: 4)
        }
        .frame(width: 8, height: 8)
    }
}

/// How long the call has been transcribed, e.g. "12:04".
struct ElapsedTime: View {
    var since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since ?? context.date)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Lays chips out in rows, wrapping onto the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
