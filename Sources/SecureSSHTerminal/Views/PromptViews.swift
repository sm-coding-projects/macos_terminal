import SwiftUI
import SecureSSHCore

/// Asks for a password at connect time (used when credentials are not
/// saved, or no saved value exists yet).
struct PasswordPromptView: View {
    @EnvironmentObject private var model: AppModel
    let request: PasswordPromptRequest
    @State private var password = ""
    @State private var save = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Password Required", systemImage: "key.fill")
                .font(.headline)
            Text("Enter the password for \(request.profile.username)@\(request.profile.host).")
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Password for \(request.profile.host)")

            if request.profile.saveCredentials {
                Toggle("Remember in Keychain", isOn: $save)
                    .accessibilityLabel("Remember password in Keychain")
            } else {
                Text("This password is used once and kept only in memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    model.completePasswordPrompt(nil)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") {
                    model.completePasswordPrompt((password: password, save: save))
                    password = ""
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear {
            // Closing the sheet via Escape/window must still resume the
            // waiting continuation.
            model.completePasswordPrompt(nil)
        }
    }
}

/// First-connection trust prompt and changed-key warning.
struct HostKeyPromptView: View {
    @EnvironmentObject private var model: AppModel
    let request: HostKeyPromptRequest

    private var question: HostKeyQuestion { request.question }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if question.isChangedKey {
                Label("Host Key Has Changed", systemImage: "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("The key presented by \(question.host):\(String(question.port)) does not match the key saved on first connection. This can indicate a man-in-the-middle attack. Do not continue unless you know the server was re-installed or re-keyed.")
                    .font(.callout)
            } else {
                Label("Verify Host Identity", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Text("This is your first connection to \(question.host):\(String(question.port)). Verify the fingerprint with the server administrator before trusting it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Key type", value: question.candidate.keyType)
                    LabeledContent("Fingerprint") {
                        Text(question.candidate.fingerprintSHA256)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    if let previous = question.previousEntry {
                        Divider()
                        LabeledContent("Previously trusted") {
                            Text(previous.fingerprintSHA256)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("Trusted on", value: previous.addedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(4)
            }
            .accessibilityLabel("Host key fingerprint \(question.candidate.fingerprintSHA256)")

            HStack {
                Button("Cancel") {
                    model.completeHostKeyPrompt(.cancel)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if question.isChangedKey {
                    Button(role: .destructive) {
                        model.completeHostKeyPrompt(.replaceAndConnect)
                    } label: {
                        Text("Replace Key and Connect")
                    }
                    .accessibilityLabel("Replace saved key and connect")
                } else {
                    Button("Connect Once") {
                        model.completeHostKeyPrompt(.trustOnce)
                    }
                    Button("Trust and Connect") {
                        model.completeHostKeyPrompt(.trustAndSave)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Trust host key and connect")
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear {
            model.completeHostKeyPrompt(.cancel)
        }
    }
}
