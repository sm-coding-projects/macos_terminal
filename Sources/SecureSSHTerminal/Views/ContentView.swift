import SwiftUI
import SecureSSHCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            detail
        }
        .navigationTitle(model.selectedProfile?.displayName ?? "SecureSSH Terminal")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.connectSelected()
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                .help("Connect to the selected server (⌘↩)")
                .accessibilityLabel("Connect to selected server")
                .disabled(model.selectedProfile == nil || model.activeSessionForSelection != nil)

                Button {
                    model.disconnectSelected()
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .help("Disconnect the active session (⇧⌘D)")
                .accessibilityLabel("Disconnect active session")
                .disabled(model.activeSessionForSelection == nil)

                Button {
                    model.beginCreatingProfile()
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .help("Add a new connection profile (⌘N)")
                .accessibilityLabel("Add new connection profile")
            }
        }
        .sheet(item: $model.editorState) { state in
            ProfileEditorView(state: state)
        }
        .sheet(item: $model.passwordPrompt) { request in
            PasswordPromptView(request: request)
        }
        .sheet(item: $model.hostKeyPrompt) { request in
            HostKeyPromptView(request: request)
        }
        .alert(item: $model.alertMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Delete “\(model.pendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                if let profile = model.pendingDeletion {
                    model.confirmDelete(profile)
                }
            }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text("Any active session will be disconnected and saved credentials for this profile will be removed from the Keychain.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profileID = model.selectedProfileID,
           let session = model.sessions[profileID] {
            SessionView(session: session)
                .id(profileID)
        } else if let profile = model.selectedProfile {
            ProfileDetailPlaceholder(profile: profile)
        } else {
            EmptyStateView()
        }
    }
}

/// Shown when a profile is selected but no session has been started yet.
struct ProfileDetailPlaceholder: View {
    @EnvironmentObject private var model: AppModel
    let profile: ConnectionProfile

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(profile.displayName)
                .font(.title2.weight(.semibold))
            Text("\(profile.username)@\(profile.host):\(String(profile.port))")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            if let lastUsed = profile.lastUsedAt {
                Text("Last used \(lastUsed.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Button {
                model.connect(profileID: profile.id)
            } label: {
                Label("Connect", systemImage: "bolt.fill")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Connect to \(profile.displayName)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("No Server Selected", systemImage: "terminal")
        } description: {
            Text("Add a connection profile, then double-click it (or press Return) to open an SSH session. Click any server to switch to it.")
        } actions: {
            Button("New Profile") { model.beginCreatingProfile() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Create a new connection profile")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
