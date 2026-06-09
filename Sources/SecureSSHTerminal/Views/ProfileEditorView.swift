import SwiftUI
import AppKit
import SecureSSHCore

/// Create/edit sheet for a connection profile.
///
/// Password and passphrase fields are transient: their values go directly
/// to the Keychain on save (when the user opted in) and are never written
/// to the profile JSON.
struct ProfileEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var password = ""
    @State private var passphrase = ""
    @State private var portText: String
    @State private var validationErrors: [ProfileValidationError] = []
    private let isNew: Bool

    init(state: ProfileEditorState) {
        _profile = State(initialValue: state.profile)
        _portText = State(initialValue: String(state.profile.port))
        isNew = state.isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Display Name", text: $profile.displayName, prompt: Text("Production Web"))
                        .accessibilityLabel("Display name")
                    TextField("Host or IP", text: $profile.host, prompt: Text("example.com"))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Host or IP address")
                    TextField("Port", text: $portText, prompt: Text("22"))
                        .accessibilityLabel("Port, defaults to 22")
                    TextField("Username", text: $profile.username, prompt: Text("admin"))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Username")
                }

                Section("Authentication") {
                    Picker("Method", selection: $profile.authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Authentication method")

                    if profile.authMethod == .password {
                        SecureField("Password", text: $password, prompt: Text(passwordPrompt))
                            .accessibilityLabel("Password")
                    } else {
                        HStack {
                            TextField(
                                "Private Key",
                                text: Binding(
                                    get: { profile.privateKeyPath ?? "" },
                                    set: { profile.privateKeyPath = $0.isEmpty ? nil : $0 }
                                ),
                                prompt: Text("~/.ssh/id_ed25519")
                            )
                            .accessibilityLabel("Private key file path")
                            Button("Choose…") { chooseKeyFile() }
                                .accessibilityLabel("Choose private key file")
                        }
                        SecureField("Key Passphrase", text: $passphrase, prompt: Text("Optional"))
                            .accessibilityLabel("Private key passphrase")
                        Text("Passphrase-protected keys are not yet supported by the SSH engine; unencrypted Ed25519 keys work best. See README.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Save credentials in Keychain", isOn: $profile.saveCredentials)
                        .accessibilityLabel("Save credentials in Keychain")
                    Toggle("Require Touch ID or password to use saved credentials", isOn: $profile.requireUserPresence)
                        .disabled(!profile.saveCredentials)
                        .accessibilityLabel("Require user presence for saved credentials")
                    if !profile.saveCredentials {
                        Text("Credentials will be requested on every connection and kept only in memory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notes") {
                    TextEditor(text: $profile.notes)
                        .frame(minHeight: 48)
                        .font(.body)
                        .accessibilityLabel("Notes")
                }

                if !validationErrors.isEmpty {
                    Section {
                        ForEach(validationErrors, id: \.self) { error in
                            Label(error.description, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add Server" : "Save Changes") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(isNew ? "Add server" : "Save changes")
            }
            .padding()
        }
        .frame(width: 480, height: 560)
    }

    private var passwordPrompt: String {
        profile.saveCredentials ? "Stored in Keychain on save" : "Asked at connect time"
    }

    private func save() {
        profile.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? -1
        profile.displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)

        validationErrors = ProfileValidator.validate(profile)
        guard validationErrors.isEmpty else { return }

        model.saveProfile(
            profile,
            newPassword: password.isEmpty ? nil : password,
            newPassphrase: passphrase.isEmpty ? nil : passphrase
        )
        // Drop transient secret state immediately.
        password = ""
        passphrase = ""
        dismiss()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose a private key file"
        if panel.runModal() == .OK, let url = panel.url {
            profile.privateKeyPath = url.path
        }
    }
}
