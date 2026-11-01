import SwiftUI

/// Settings → Dictation → Compare engines: read a passage once, then see how
/// Apple's engine and Parakeet did on exactly the same recording.
struct EngineComparisonView: View {
    @StateObject private var benchmark: EngineBenchmark
    @Environment(\.dismiss) private var dismiss

    init(appState: AppState, lexicon: LexiconStore) {
        _benchmark = StateObject(wrappedValue: EngineBenchmark(appState: appState, lexicon: lexicon))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare speech engines").font(.title2.bold())
            Text("Read the passage below out loud at your normal pace. Warble then gives the same recording to Apple's engine and to Parakeet, and scores each one. Nothing leaves this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(benchmark.passage)
                .font(.title3)
                .lineSpacing(4)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WarbleColor.surface, in: RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)
            if !benchmark.terms.isEmpty {
                Text("The last sentence uses words from your Word List, to test jargon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            controls

            if !benchmark.results.isEmpty {
                resultsTable
            }
            Spacer(minLength: 0)
            HStack {
                if let url = benchmark.savedReport {
                    Button("Show report in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copy results") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(benchmark.reportMarkdown, forType: .string)
                    }
                }
                Spacer()
                Button("Close") {
                    benchmark.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 720)
        .warbleTheme()
    }

    @ViewBuilder
    private var controls: some View {
        switch benchmark.phase {
        case .idle, .done, .failed:
            HStack {
                Button(benchmark.phase == .idle ? "Start recording" : "Record again") { benchmark.startRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if case .failed(let message) = benchmark.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .recording:
            HStack(spacing: 12) {
                WaveformRibbon(level: benchmark.level, isActive: true).frame(width: 60, height: 28)
                Text(String(format: "Recording… %.0f s", benchmark.recordedSeconds))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button("Stop and compare") { benchmark.stopAndCompare() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        case .analysing(let step):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(step)
            }
        }
    }

    private var resultsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(benchmark.results) { Text($0.name).font(.headline) }
            }
            Divider()
            row("Words right") { String(format: "%.1f%%", $0.accuracy * 100) }
            row("Word errors") { "\($0.score.errors) of \($0.score.referenceWords)" }
            if !benchmark.terms.isEmpty {
                row("Word List terms heard") { "\(benchmark.terms.count - $0.missedTerms.count) of \(benchmark.terms.count)" }
            }
            row("Time to transcribe") { String(format: "%.2f s", $0.processingSeconds) }
            row("Speed") { String(format: "%.0f× real time", $0.speed) }
            row("Model load") { String(format: "%.1f s", $0.loadSeconds) }
            Divider()
            ForEach(benchmark.results) { result in
                GridRow {
                    Text("\(result.name) heard").foregroundStyle(.secondary)
                    Text(result.transcript.isEmpty ? "(nothing)" : result.transcript)
                        .font(.caption)
                        .textSelection(.enabled)
                        .gridCellColumns(max(1, benchmark.results.count))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ label: String, _ value: @escaping (EngineBenchmark.EngineResult) -> String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            ForEach(benchmark.results) { Text(value($0)).monospacedDigit() }
        }
    }
}
