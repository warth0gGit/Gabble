import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns a call into a tidy PDF for sending to people: the meeting's name,
/// when it was, who was on, the summary, optionally the actions, and the
/// full transcript. Black on white whatever the Mac's appearance.
@MainActor
enum CallSharePDF {
    private static let margin: CGFloat = 54

    /// The PDF in a temporary folder, or nil if it couldn't be made.
    static func make(_ call: SharedCall, options: SharedCall.Options) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Warble Share", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(call.fileName)
        try? FileManager.default.removeItem(at: url)

        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return nil }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - 2 * margin
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.drawsBackground = true
        text.backgroundColor = .white
        text.textStorage?.setAttributedString(document(call, options: options))
        if let container = text.textContainer, let layout = text.layoutManager {
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height
            text.setFrameSize(NSSize(width: width, height: ceil(height) + 4))
        }

        let operation = NSPrintOperation(view: text, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Layout

    static func document(_ call: SharedCall, options: SharedCall.Options) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ink = NSColor.black
        let grey = NSColor(white: 0.38, alpha: 1)

        func paragraph(spacingBefore: CGFloat = 0, after: CGFloat = 4, indent: CGFloat = 0, hanging: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = after
            p.firstLineHeadIndent = indent
            p.headIndent = indent + hanging
            p.lineHeightMultiple = 1.12
            return p
        }
        func add(_ string: String, font: NSFont, color: NSColor = ink, style: NSParagraphStyle) {
            out.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        func heading(_ title: String) {
            add(title, font: .systemFont(ofSize: 13, weight: .semibold), style: paragraph(spacingBefore: 14, after: 6))
        }
        func bullets(_ items: [String]) {
            for item in items {
                add("•\t" + item, font: .systemFont(ofSize: 11), style: {
                    let p = paragraph(after: 3, hanging: 14).mutableCopy() as! NSMutableParagraphStyle
                    p.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
                    p.defaultTabInterval = 14
                    return p
                }())
            }
        }

        add(call.name, font: .systemFont(ofSize: 20, weight: .bold), style: paragraph(after: 4))
        if let when = call.when {
            add(when, font: .systemFont(ofSize: 11), color: grey, style: paragraph(after: 2))
        }
        if !call.people.isEmpty {
            add("Attendees: " + call.people.joined(separator: ", "), font: .systemFont(ofSize: 11), color: grey,
                style: paragraph(after: 6))
        }

        if options.summary {
            if call.summary.isEmpty && call.keyPoints.isEmpty && call.decisions.isEmpty {
                heading("Summary")
                add("No summary was written for this call.", font: .systemFont(ofSize: 11), color: grey, style: paragraph())
            } else {
                if !call.summary.isEmpty { heading("Summary"); bullets(call.summary) }
                if !call.keyPoints.isEmpty { heading("Key points"); bullets(call.keyPoints) }
                if !call.decisions.isEmpty { heading("Decisions"); bullets(call.decisions) }
            }
        }
        if options.actions, !call.actions.isEmpty {
            heading("Actions")
            bullets(call.actions.map(SharedCall.describe))
        }
        if options.transcript, !call.transcript.isEmpty {
            heading("Transcript")
            for line in call.transcript {
                let p = paragraph(after: 5)
                out.append(NSAttributedString(string: "\(line.speaker) ", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: ink, .paragraphStyle: p,
                ]))
                out.append(NSAttributedString(string: "\(line.time)  ", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: grey, .paragraphStyle: p,
                ]))
                add(line.text, font: .systemFont(ofSize: 10), style: p)
            }
        }
        return out
    }
}

/// Shows the Mac's Share menu (Mail, Outlook, Messages, AirDrop...) for a file.
@MainActor
final class ShareMenu: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareMenu()
    private var onDone: ((Bool) -> Void)?

    func show(_ items: [Any], from view: NSView, onDone: @escaping (Bool) -> Void) {
        self.onDone = onDone
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            onDone?(service != nil)
            onDone = nil
        }
    }
}

/// Gives SwiftUI a real view to show the Share menu from.
struct ShareAnchor: NSViewRepresentable {
    let holder: Holder

    final class Holder {
        weak var view: NSView?
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// "Share this call": pick what goes in, then send the PDF from the Share menu.
struct ShareCallSheet: View {
    let note: URL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("share.summary") private var includeSummary = true
    @AppStorage("share.actions") private var includeActions = false
    @AppStorage("share.transcript") private var includeTranscript = true
    @AppStorage("share.myName") private var myName = NSFullUserName()
    @State private var call: SharedCall?
    @State private var problem: String?
    @State private var anchor = ShareAnchor.Holder()

    private var options: SharedCall.Options {
        SharedCall.Options(summary: includeSummary, actions: includeActions, transcript: includeTranscript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share this call").font(.title3.weight(.semibold))
            if let call {
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.name).font(.headline)
                    if let when = call.when { Text(when).font(.callout).foregroundStyle(.secondary) }
                    if !call.people.isEmpty {
                        Text(call.people.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("The PDF always has the name, date and time, and who was on. Also include:")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Summary", isOn: $includeSummary)
                    Toggle(call.actions.isEmpty ? "Actions (none on this call)" : "Actions (\(call.actions.count))",
                           isOn: $includeActions)
                        .disabled(call.actions.isEmpty)
                    Toggle("Full transcript", isOn: $includeTranscript)
                        .disabled(call.transcript.isEmpty)
                }
                TextField("Your name (shown instead of \"Me\")", text: $myName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(load)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save PDF…", action: savePDF)
                    .disabled(call == nil)
                Button("Share…", action: share)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(call == nil)
                    .background(ShareAnchor(holder: anchor))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
        .onChange(of: myName) { _, _ in load() }
    }

    private func load() {
        guard let text = try? String(contentsOf: note, encoding: .utf8) else {
            problem = "Couldn't read this call's note. It may have been moved or renamed."
            call = nil
            return
        }
        call = SharedCall.parse(note: text, me: myName)
        problem = nil
    }

    private func pdf() -> URL? {
        guard let call else { return nil }
        guard let url = CallSharePDF.make(call, options: options) else {
            problem = "Couldn't make the PDF."
            return nil
        }
        return url
    }

    private func share() {
        guard let url = pdf(), let view = anchor.view else { return }
        ShareMenu.shared.show([url], from: view) { sent in
            if sent { dismiss() }
        }
    }

    private func savePDF() {
        guard let url = pdf() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            dismiss()
        } catch {
            problem = "Couldn't save the PDF there."
        }
    }
}
