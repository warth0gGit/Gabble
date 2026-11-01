import AppKit
import Combine
import SwiftUI

/// The menu bar icon. Click it to start dictating, click again to stop and type the text.
/// Right-click (or Control-click) for a small menu with everything else.
/// Clicking never brings Warble to the front, so the text goes to the app you were using.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    /// Set by the main window so the menu can reopen it.
    var openMainWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var appState: AppState?
    private var dictation: DictationController?
    private var calls: CallController?
    private var permissions: PermissionsManager?
    private var cancellables: Set<AnyCancellable> = []
    private var animationTimer: Timer?

    func install(appState: AppState, dictation: DictationController, calls: CallController,
                 permissions: PermissionsManager) {
        guard statusItem == nil else { return }
        self.appState = appState
        self.dictation = dictation
        self.calls = calls
        self.permissions = permissions

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // @Published fires before the value changes, so read the new state on the next run loop turn.
        appState.$dictationEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateChanged() }
            .store(in: &cancellables)
        dictation.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateChanged() }
            .store(in: &cancellables)
        calls.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateChanged() }
            .store(in: &cancellables)

        stateChanged()
    }

    // MARK: - Drawing

    private var isListening: Bool { dictation?.phase == .listening }
    private var isTranscribingCall: Bool { calls?.isRecording == true }

    private func stateChanged() {
        if isListening || isTranscribingCall {
            if animationTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.redraw() }
                }
                RunLoop.main.add(timer, forMode: .common)
                animationTimer = timer
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        redraw()
    }

    private func redraw() {
        guard let button = statusItem?.button, let dictation else { return }
        let time = Date().timeIntervalSinceReferenceDate
        // During a call the wave moves gently on its own; dictation follows your voice.
        let level = isListening ? dictation.level : 0.35 + 0.15 * sin(time * 2)
        button.image = MenuBarIcon.image(
            time: time,
            listening: isListening || isTranscribingCall,
            enabled: dictation.phase == .idle || isListening,
            level: level
        )
        let tip: String
        switch dictation.phase {
        case .listening: tip = "Listening. Click to stop and type what you said."
        case .processing: tip = "Tidying up your words…"
        case .preparing(let message): tip = message
        case .idle:
            tip = isTranscribingCall
                ? "Transcribing this call. Right-click to stop."
                : "Click to start dictating. Right-click for more."
        }
        button.toolTip = tip
        let label = isListening ? "Warble, listening" : isTranscribingCall ? "Warble, transcribing a call" : "Warble"
        button.setAccessibilityLabel(label)
    }

    // MARK: - Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            dictation?.toggleHandsFree()
        }
    }

    @objc private func toggleShortcut() {
        appState?.dictationEnabled.toggle()
    }

    private func showMenu() {
        guard let statusItem, let appState, let dictation else { return }
        permissions?.refresh()
        let menu = NSMenu()

        let hint = NSMenuItem(title: "Click the wave to start or stop dictating", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let shortcut = NSMenuItem(title: "Hold the \(appState.dictationKey.displayName) to talk", action: #selector(toggleShortcut), keyEquivalent: "")
        shortcut.target = self
        shortcut.state = appState.dictationEnabled ? .on : .off
        menu.addItem(shortcut)

        if calls?.isRecording == true {
            menu.addItem(.separator())
            let stop = NSMenuItem(title: "Stop transcribing this call", action: #selector(stopCall), keyEquivalent: "")
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            stop.target = self
            menu.addItem(stop)
        }

        if let error = dictation.lastError {
            menu.addItem(.separator())
            let item = NSMenuItem(title: Self.shorten(error), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem")
            item.isEnabled = false
            item.toolTip = error
            menu.addItem(item)
        }

        if permissions?.allRequiredGranted == false {
            let item = NSMenuItem(title: "Approve permissions…", action: #selector(openWindow), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
        }

        if !dictation.lastResult.isEmpty {
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy last dictation", action: #selector(copyLast), keyEquivalent: "")
            copy.target = self
            copy.toolTip = dictation.lastResult
            menu.addItem(copy)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Warble…", action: #selector(openWindow), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Warble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Attach the menu just for this click, so a normal click stays a toggle.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func stopCall() {
        calls?.stopRecording()
    }

    @objc private func copyLast() {
        guard let text = dictation?.lastResult, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openWindow() {
        NSApp.activate()
        if let openMainWindow {
            openMainWindow()
        } else {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "…" : text
    }
}

/// Lets the menu bar menu reopen the main window after it has been closed.
struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                StatusItemController.shared.openMainWindow = { openWindow(id: WindowID.main) }
            }
    }
}
