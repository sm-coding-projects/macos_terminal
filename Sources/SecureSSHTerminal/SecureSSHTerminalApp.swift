import SwiftUI
import AppKit
import SecureSSHCore

@main
struct SecureSSHTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile") { model.beginCreatingProfile() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Connection") {
                Button("Connect") { model.connectSelected() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedProfile == nil)
                Button("Disconnect") { model.disconnectSelected() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.activeSessionForSelection == nil)
                Divider()
                Button("Edit Profile…") { model.beginEditingSelectedProfile() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selectedProfile == nil)
                Button("Duplicate Profile") { model.duplicateSelectedProfile() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedProfile == nil)
                Button("Delete Profile…") { model.requestDeleteSelectedProfile() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedProfile == nil)
            }
            CommandMenu("Terminal") {
                Button("Clear Screen") { model.clearActiveTerminal() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.activeSessionForSelection == nil)
                Button("Send Interrupt (Ctrl+C)") { model.activeSessionForSelection?.sendInterrupt() }
                    .disabled(model.activeSessionForSelection == nil)
                Button("Send EOF (Ctrl+D)") { model.activeSessionForSelection?.sendEOF() }
                    .disabled(model.activeSessionForSelection == nil)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Confirms before quitting while sessions are active, and makes the bare
/// SPM executable behave like a regular app (Dock icon, key window).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let activeCount = AppModel.shared.activeSessionCount
        guard activeCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = activeCount == 1
            ? "1 SSH session is still active."
            : "\(activeCount) SSH sessions are still active."
        alert.informativeText = "Quitting will disconnect all active sessions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disconnect and Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppModel.shared.disconnectAll()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
