import SwiftUI
import SecureSSHCore

/// Identifies a profile being created or edited in the sheet.
struct ProfileEditorState: Identifiable {
    let id = UUID()
    var profile: ConnectionProfile
    var isNew: Bool
}

struct PasswordPromptRequest: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let continuation: CheckedContinuation<(password: String, save: Bool)?, Never>
}

struct HostKeyPromptRequest: Identifiable {
    let id = UUID()
    let question: HostKeyQuestion
    let continuation: CheckedContinuation<HostKeyDecision, Never>
}

struct AppAlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Transient confirmation shown after copy-on-select in the terminal.
struct CopyNotice: Identifiable, Equatable {
    let id = UUID()
    let characterCount: Int
}

/// Root application state: profile list, live sessions, and the
/// continuation-based bridges that let async core flows present SwiftUI
/// sheets (password prompts, host-key trust dialogs).
@MainActor
final class AppModel: ObservableObject, UserPrompting {
    static let shared = AppModel()

    @Published var profiles: [ConnectionProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var searchText = ""
    @Published private(set) var sessions: [UUID: TerminalViewModel] = [:]
    @Published var editorState: ProfileEditorState?
    @Published var passwordPrompt: PasswordPromptRequest?
    @Published var hostKeyPrompt: HostKeyPromptRequest?
    @Published var alertMessage: AppAlertMessage?
    @Published var pendingDeletion: ConnectionProfile?
    /// Incremented to ask the focused terminal to clear.
    @Published var clearTerminalSignal = 0
    @Published var copyNotice: CopyNotice?
    private var copyNoticeDismissal: Task<Void, Never>?

    private let profileStore: any ProfileStoring
    let secrets: ProfileSecretsManager
    private let knownHosts: any KnownHostsServicing
    private let sshService: any SSHSessionServicing

    init(
        profileStore: (any ProfileStoring)? = nil,
        keychain: (any KeychainServicing)? = nil,
        knownHosts: (any KnownHostsServicing)? = nil,
        sshService: (any SSHSessionServicing)? = nil
    ) {
        self.profileStore = profileStore ?? ((try? JSONProfileStore()) ?? InMemoryProfileStore())
        self.secrets = ProfileSecretsManager(keychain: keychain ?? MacKeychainService())
        self.knownHosts = knownHosts ?? ((try? FileKnownHostsService()) ?? UnavailableKnownHosts())
        self.sshService = sshService ?? NIOSSHSessionService()
        loadProfiles()
    }

    // MARK: Profiles

    var filteredProfiles: [ConnectionProfile] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = profiles.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
                || $0.username.lowercased().contains(needle)
        }
    }

    var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var activeSessionForSelection: TerminalViewModel? {
        guard let id = selectedProfileID, let session = sessions[id], session.state.isActive else {
            return nil
        }
        return session
    }

    var activeSessionCount: Int {
        sessions.values.filter { $0.state.isActive }.count
    }

    private func loadProfiles() {
        do {
            profiles = try profileStore.loadProfiles()
        } catch {
            alertMessage = AppAlertMessage(
                title: "Could Not Load Profiles",
                message: Redactor.describe(error)
            )
        }
    }

    private func persistProfiles() {
        do {
            try profileStore.saveProfiles(profiles)
        } catch {
            alertMessage = AppAlertMessage(
                title: "Could Not Save Profiles",
                message: Redactor.describe(error)
            )
        }
    }

    func beginCreatingProfile() {
        editorState = ProfileEditorState(profile: ConnectionProfile(), isNew: true)
    }

    func beginEditingSelectedProfile() {
        guard let profile = selectedProfile else { return }
        editorState = ProfileEditorState(profile: profile, isNew: false)
    }

    /// Saves the profile and (when provided) routes secrets to the Keychain.
    /// Secrets are passed transiently from the editor; they are never stored
    /// on the profile or in the JSON store.
    func saveProfile(
        _ profile: ConnectionProfile,
        newPassword: String?,
        newPassphrase: String?
    ) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persistProfiles()
        selectedProfileID = profile.id

        do {
            if profile.saveCredentials {
                if let newPassword, !newPassword.isEmpty {
                    try secrets.savePassword(newPassword, for: profile)
                }
                if let newPassphrase, !newPassphrase.isEmpty {
                    try secrets.savePassphrase(newPassphrase, for: profile)
                }
            } else {
                // Saving switched off: purge anything previously stored.
                try secrets.deleteAllSecrets(for: profile.id)
            }
        } catch {
            alertMessage = AppAlertMessage(
                title: "Keychain Error",
                message: Redactor.describe(error, secrets: [newPassword, newPassphrase])
            )
        }
    }

    func duplicateSelectedProfile() {
        guard let profile = selectedProfile else { return }
        let copy = profile.duplicated()
        profiles.append(copy)
        persistProfiles()
        selectedProfileID = copy.id
    }

    func requestDeleteSelectedProfile() {
        pendingDeletion = selectedProfile
    }

    /// Deletes the profile, disconnects any session, and removes all
    /// associated Keychain items.
    func confirmDelete(_ profile: ConnectionProfile) {
        if let session = sessions[profile.id] {
            Task { await session.disconnect() }
            sessions.removeValue(forKey: profile.id)
        }
        TerminalViewCache.remove(profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        persistProfiles()
        do {
            try secrets.deleteAllSecrets(for: profile.id)
        } catch {
            alertMessage = AppAlertMessage(
                title: "Keychain Cleanup Failed",
                message: Redactor.describe(error)
            )
        }
        if selectedProfileID == profile.id {
            selectedProfileID = nil
        }
        pendingDeletion = nil
    }

    // MARK: Sessions

    func connect(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        selectedProfileID = profileID

        if let existing = sessions[profileID], existing.state.isActive {
            return // already connected/connecting; just focus it
        }

        let session = TerminalViewModel(
            profile: profile,
            sshService: sshService,
            knownHosts: knownHosts,
            secrets: secrets,
            prompts: self
        )
        session.onConnected = { [weak self] in
            self?.markUsed(profileID: profileID)
        }
        sessions[profileID] = session
        Task { await session.connect() }
    }

    func connectSelected() {
        guard let id = selectedProfileID else { return }
        connect(profileID: id)
    }

    func disconnectSelected() {
        guard let session = activeSessionForSelection else { return }
        Task { await session.disconnect() }
    }

    func disconnectAll() {
        for session in sessions.values where session.state.isActive {
            Task { await session.disconnect() }
        }
    }

    func clearActiveTerminal() {
        clearTerminalSignal += 1
    }

    /// Shows the copy-on-select confirmation, replacing any visible one and
    /// restarting the auto-dismiss timer.
    func announceCopy(characterCount: Int) {
        let notice = CopyNotice(characterCount: characterCount)
        copyNotice = notice
        copyNoticeDismissal?.cancel()
        copyNoticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if self?.copyNotice?.id == notice.id {
                self?.copyNotice = nil
            }
        }
    }

    private func markUsed(profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].lastUsedAt = Date()
        persistProfiles()
    }

    // MARK: UserPrompting (continuation bridges to SwiftUI sheets)

    nonisolated func requestPassword(for profile: ConnectionProfile) async -> (password: String, save: Bool)? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.passwordPrompt = PasswordPromptRequest(profile: profile, continuation: continuation)
            }
        }
    }

    nonisolated func resolveHostKey(_ question: HostKeyQuestion) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.hostKeyPrompt = HostKeyPromptRequest(question: question, continuation: continuation)
            }
        }
    }

    func completePasswordPrompt(_ result: (password: String, save: Bool)?) {
        passwordPrompt?.continuation.resume(returning: result)
        passwordPrompt = nil
    }

    func completeHostKeyPrompt(_ decision: HostKeyDecision) {
        hostKeyPrompt?.continuation.resume(returning: decision)
        hostKeyPrompt = nil
    }
}

/// Fallback used only if Application Support is unavailable; refuses every
/// connection rather than degrade host-key checking.
private final class UnavailableKnownHosts: KnownHostsServicing {
    func evaluate(candidate: HostKeyCandidate, host: String, port: Int) -> HostKeyVerdict {
        .changed(stored: KnownHostEntry(
            host: host,
            port: port,
            candidate: HostKeyCandidate(openSSHString: "unavailable known-hosts-store")
        ))
    }
    func trust(candidate: HostKeyCandidate, host: String, port: Int) throws {
        throw KnownHostsError.ioFailure("known-hosts store unavailable")
    }
    func replace(candidate: HostKeyCandidate, host: String, port: Int) throws {
        throw KnownHostsError.ioFailure("known-hosts store unavailable")
    }
    func remove(host: String, port: Int) throws {}
    func allEntries() -> [KnownHostEntry] { [] }
}
