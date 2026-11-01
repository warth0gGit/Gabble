import AppKit
import SwiftUI

/// A small floating card in the top-right corner for calls: "Transcribe this call?",
/// "Identify Speaker" and "Transcript saved". While a call is transcribed it stays
/// hidden; the menu bar icon shows that instead. It can be clicked without taking
/// focus away from the call.
@MainActor
final class CallPanel {
    private let panel: NSPanel

    /// A borderless panel that can still take typing (for "Identify Speaker").
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
        self.host = host
    }

    private var host: NSView?

    func show() {
        fitToScreen()
        panel.orderFrontRegardless()
        // SwiftUI may redraw the card a moment later with new content; fit again then.
        DispatchQueue.main.async { [weak self] in self?.fitToScreen() }
    }

    /// Fits the panel to the card and pins it to the top-right corner,
    /// so it never covers more of the screen than it needs to.
    private func fitToScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        host?.layoutSubtreeIfNeeded()
        var size = host?.fittingSize ?? panel.frame.size
        size.width = 340
        size.height = max(60, size.height)
        panel.setFrame(NSRect(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct CallPanelView: View {
    @EnvironmentObject private var calls: CallController
    @State private var whoName = ""

    var body: some View {
        card
            .frame(width: 340)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark)
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
        if calls.askingWho != nil {
            identifySpeaker
        } else if let error = calls.lastError, calls.state == .idle {
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
            case .recording:
                EmptyView()
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

    /// "Identify Speaker": a black card with the Warble logo and a name box.
    /// It goes away as soon as a name is entered.
    @ViewBuilder
    private var identifySpeaker: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("Warble").font(.headline)
            Spacer()
            Button {
                whoName = ""
                calls.skipVoice()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Not now")
        }
        TextField("Identify Speaker", text: $whoName)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .onSubmit(saveName)
        if let sample = calls.askingWho?.sample, !sample.isEmpty {
            Text("Said: \u{201C}\(sample)\u{201D}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
        }
    }

    private func saveName() {
        calls.nameVoice(whoName)
        whoName = ""
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
    }
}
