import SwiftUI
import AppKit
import SwiftTerm
import SecureSSHCore

/// SwiftUI wrapper around SwiftTerm's `TerminalView`, wired to a
/// `TerminalViewModel`: keystrokes go to the SSH channel, SSH output is fed
/// to the emulator, and size changes propagate as SSH window-change requests.
struct TerminalHostView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalViewModel
    @AppStorage("terminalFontSize") private var fontSize: Double = 13
    @AppStorage("multiLinePasteWarning") private var pasteWarning = true

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> PasteGuardTerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        let view = PasteGuardTerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.warnOnMultiLinePaste = pasteWarning
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)

        session.attachOutput { [weak view] data in
            view?.feed(byteArray: ArraySlice([UInt8](data)))
        }
        return view
    }

    func updateNSView(_ view: PasteGuardTerminalView, context: Context) {
        view.warnOnMultiLinePaste = pasteWarning
        context.coordinator.clearIfSignaled(model.clearTerminalSignal, view: view)
        if session.state == .connected, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: TerminalViewModel
        private var lastClearSignal = 0

        init(session: TerminalViewModel) {
            self.session = session
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
            guard newCols > 0, newRows > 0 else { return }
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
