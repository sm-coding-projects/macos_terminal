import SwiftUI

/// App preferences. Only non-secret display/behavior settings live here
/// (UserDefaults). Credentials are exclusively in the Keychain.
struct SettingsView: View {
    @AppStorage("terminalFontSize") private var fontSize: Double = 13
    @AppStorage("multiLinePasteWarning") private var pasteWarning = true

    var body: some View {
        Form {
            Section("Terminal") {
                Slider(value: $fontSize, in: 10...20, step: 1) {
                    Text("Font Size: \(Int(fontSize)) pt")
                }
                .accessibilityLabel("Terminal font size")
                Text("Applies to newly opened sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Safety") {
                Toggle("Warn before pasting multiple lines", isOn: $pasteWarning)
                    .accessibilityLabel("Warn before pasting multiple lines")
            }
            Section("Privacy") {
                Label("No telemetry. This app sends data only to the SSH servers you connect to.", systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
