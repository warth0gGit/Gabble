import AppKit
import SwiftUI

/// A small floating card in the top-right corner for call transcription:
/// the "Transcribe this call?" question, then a recording indicator with Stop.
/// It can be clicked without taking focus away from the call.
@MainActor
final class CallPanel {
    private let panel: NSPanel

    /// A borderless panel that can still take typing (for "Who is talking?").
    private final class TypingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(controller: CallController) {
        panel = TypingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 210),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CallPanelView().environmentObject(controller))
        host.frame = panel.contentLayoutRect
        panel.contentView = host
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct CallPanelView: View {
    @EnvironmentObject private var calls: CallController
    @State private var whoName = ""

    var body: some View {
        VStack {
            card
            Spacer(minLength: 0)
        }
        .frame(width: 340, height: 210, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WarbleColor.surface, in: RoundedRectangle(cornerRadius: 14))
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
            case .recording where calls.askingWho != nil:
                whoIsTalking
            case .recording(let appName):
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Transcribing \(shortName(appName)) call").font(.headline)
                    Spacer()
                    if let start = calls.recordingStarted {
                        Text(start, style: .timer)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(latestLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Stop") { calls.stopRecording() }
                }
            case .saving:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving transcript…").font(.headline)
                }
            case .saved(let url):
                Label("Transcript saved", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(WarbleColor.green)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                }
            case .idle:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var whoIsTalking: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("Who is talking?").font(.headline)
        }
        if let sample = calls.askingWho?.sample, !sample.isEmpty {
            Text("\u{201C}\(sample)\u{201D}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
        } else {
            Text("Warble hears a voice it doesn't know yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        TextField("Their name", text: $whoName)
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveName)
        HStack {
            Button("Skip") { whoName = ""; calls.skipVoice() }
            Spacer()
            Button("Save", action: saveName)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(whoName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("Warble will recognise them on future calls.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func saveName() {
        calls.nameVoice(whoName)
        whoName = ""
    }

    private var latestLine: String {
        if !calls.liveOthers.isEmpty { return "Others: " + calls.liveOthers }
        if !calls.liveMe.isEmpty { return "Me: " + calls.liveMe }
        if let last = calls.transcript?.ordered.last { return "\(calls.label(for: last)): \(last.text)" }
        return "Listening…"
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
    }
}
