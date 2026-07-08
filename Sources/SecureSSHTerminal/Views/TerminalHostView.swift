import SwiftUI
import AppKit
import SwiftTerm
import SecureSSHCore

/// Single source of truth for the terminal font size, shared by the
/// menu commands, the ⌘+/⌘- key handling in the terminal view, and the
/// Settings slider (all read/write the same UserDefaults key).
enum TerminalFontSize {
    static let key = "terminalFontSize"
    static let defaultSize: Double = 13
    static let range: ClosedRange<Double> = 9...28

    static var current: Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored == 0 ? defaultSize : stored.clamped(to: range)
    }

    static func adjust(by delta: Double) {
        UserDefaults.standard.set((current + delta).clamped(to: range), forKey: key)
    }

    static func reset() {
        UserDefaults.standard.set(defaultSize, forKey: key)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Keeps one live terminal view per profile. Switching servers changes the
/// detail view's identity, which tears down and rebuilds the SwiftUI
/// representable — re-hosting the cached NSView here means the emulator
/// (screen contents and scrollback) survives the switch.
@MainActor
enum TerminalViewCache {
    fileprivate static var views: [UUID: PasteGuardTerminalView] = [:]

    static func remove(profileID: UUID) {
        views.removeValue(forKey: profileID)
    }
}

/// SwiftUI wrapper around SwiftTerm's `TerminalView`, wired to a
/// `TerminalViewModel`: keystrokes go to the SSH channel, SSH output is fed
/// to the emulator, and size changes propagate as SSH window-change requests.
struct TerminalHostView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalViewModel
    @AppStorage("multiLinePasteWarning") private var pasteWarning = true

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> PasteGuardTerminalView {
        let view: PasteGuardTerminalView
        if let cached = TerminalViewCache.views[session.id] {
            view = cached
        } else {
            let font = NSFont.monospacedSystemFont(ofSize: CGFloat(TerminalFontSize.current), weight: .regular)
            view = PasteGuardTerminalView(frame: .zero, font: font)
            view.nativeBackgroundColor = .black
            view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
            TerminalViewCache.views[session.id] = view
        }
        view.terminalDelegate = context.coordinator
        view.warnOnMultiLinePaste = pasteWarning
        let model = self.model
        view.onSelectionCopied = { count in
            model.announceCopy(characterCount: count)
        }
        context.coordinator.attach(to: view, session: session)
        return view
    }

    func updateNSView(_ view: PasteGuardTerminalView, context: Context) {
        view.warnOnMultiLinePaste = pasteWarning
        if context.coordinator.session !== session {
            // A reconnect creates a fresh view model for the same profile;
            // point its output at the retained view.
            context.coordinator.attach(to: view, session: session)
        }
        context.coordinator.clearIfSignaled(model.clearTerminalSignal, view: view)
        if session.state == .connected, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private(set) var session: TerminalViewModel
        private var lastClearSignal = 0

        init(session: TerminalViewModel) {
            self.session = session
        }

        @MainActor
        func attach(to view: PasteGuardTerminalView, session: TerminalViewModel) {
            self.session = session
            session.attachOutput { [weak view] data in
                view?.feed(byteArray: ArraySlice([UInt8](data)))
            }
        }

        @MainActor
        func clearIfSignaled(_ signal: Int, view: TerminalView) {
            guard signal != lastClearSignal else { return }
            lastClearSignal = signal
            // Clear screen + scrollback locally, then ask the remote shell
            // to redraw its prompt.
            view.getTerminal().resetToInitialState()
            view.setNeedsDisplay(view.bounds)
            session.send(Data([0x0C])) // Ctrl+L
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            // SwiftTerm invokes its delegate on the main thread.
            MainActor.assumeIsolated {
                session.send(bytes)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Never propagate a grid the remote shell can't render a prompt
            // in; transient layout passes can report absurd sizes.
            guard newCols >= 10, newRows >= 3 else { return }
            MainActor.assumeIsolated {
                session.resize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
        func bell(source: TerminalView) {
            NSSound.beep()
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(str, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// TerminalView subclass that warns before pasting multi-line content —
/// a pasted newline executes commands immediately on the remote host.
final class PasteGuardTerminalView: TerminalView {
    var warnOnMultiLinePaste = true
    /// Called with the character count after a selection is auto-copied.
    var onSelectionCopied: ((Int) -> Void)?
    private var defaultsObserver: NSObjectProtocol?

    /// Copy-on-select, via a local event monitor because SwiftTerm's
    /// `mouseUp` is public-not-open and cannot be overridden. A plain click
    /// clears the selection on mouse-down, so an active selection at
    /// mouse-up always means the user just made one (drag, double-click
    /// word, triple-click line, or shift-extend).
    private var mouseUpMonitor: Any?

    private func installCopyOnSelectMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // Defer one turn so SwiftTerm finishes processing the mouse-up
            // before the selection is read.
            DispatchQueue.main.async { [weak self] in
                self?.copySelectionIfMouseUpWasHere(event)
            }
            return event
        }
    }

    private func removeCopyOnSelectMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }

    private func copySelectionIfMouseUpWasHere(_ event: NSEvent) {
        guard let window, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let text = getSelection(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onSelectionCopied?(text.count)
    }

    /// SwiftUI's hosting layout passes through degenerate sizes while the
    /// view is detached/re-hosted during a server switch. SwiftTerm has no
    /// lower bound on the grid: a transient 2-column layout reflows the
    /// scrollback and tells the remote shell the window is 2 cells wide,
    /// which makes bash redraw its prompt as "ro…"/"me…". Ignore any size
    /// that cannot hold a usable grid; the final layout pass always
    /// delivers the real size.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width >= 100, newSize.height >= 50 else { return }
        super.setFrameSize(newSize)
    }

    /// Called whenever the (cached) view is hosted into the window — i.e.
    /// every time the user switches to this server.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeCopyOnSelectMonitor()
            return
        }
        installCopyOnSelectMonitor()

        // Repaint everything from the emulator's buffer. Dirty-row redraw
        // requests issued while the view was detached (output arriving for
        // a background server) are lost, which left the prompt partially
        // drawn after a switch.
        needsDisplay = true

        // Focus the terminal immediately so the user can type right after
        // selecting a server, without clicking into the terminal first.
        // Deferred one runloop turn so it wins over the sidebar List, which
        // takes focus from the click that triggered the switch.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }

        // Observe the font-size preference directly so changes from any
        // source (menu, ⌘+/⌘-, Settings slider) apply to live terminals
        // immediately. SwiftUI's updateNSView is not a reliable channel
        // here: it only runs when a tracked dependency changes.
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.applyPreferredFontSize()
        }
        applyPreferredFontSize()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
    }

    private func applyPreferredFontSize() {
        let size = CGFloat(TerminalFontSize.current)
        guard abs(font.pointSize - size) > 0.1 else { return }
        // Setting `font` makes SwiftTerm re-layout the grid and report the
        // new cols/rows, which propagates to SSH as a window-change.
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Handle ⌘+ / ⌘= / ⌘- / ⌘0 directly: the terminal is first responder
    /// while the user types, and this also makes ⌘= (the unshifted "+" key)
    /// work, which menu key-equivalents alone would not.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                TerminalFontSize.adjust(by: 1)
                return true
            case "-":
                TerminalFontSize.adjust(by: -1)
                return true
            case "0":
                TerminalFontSize.reset()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any) {
        guard warnOnMultiLinePaste,
              let text = NSPasteboard.general.string(forType: .string),
              text.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            super.paste(sender)
            return
        }

        let lineCount = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).count
        let alert = NSAlert()
        alert.messageText = "Paste \(lineCount) lines?"
        alert.informativeText = "The clipboard contains line breaks. Pasting will execute each line as a command on the remote host."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            super.paste(sender)
        }
    }
}
