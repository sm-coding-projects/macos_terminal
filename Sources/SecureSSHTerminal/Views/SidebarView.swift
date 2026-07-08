import SwiftUI
import SecureSSHCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section("Servers") {
                if model.filteredProfiles.isEmpty {
                    if model.profiles.isEmpty {
                        Text("No saved servers yet")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No saved servers yet")
                    } else {
                        Text("No matches for “\(model.searchText)”")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.filteredProfiles) { profile in
                    ProfileRow(profile: profile, session: model.sessions[profile.id])
                        .tag(profile.id)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            // Explicit single-click selection: without this the
                            // List's own selection waits on the double-click
                            // recognizer below, so switching needed two clicks.
                            TapGesture().onEnded {
                                model.selectedProfileID = profile.id
                            }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                model.connect(profileID: profile.id)
                            }
                        )
                        .contextMenu {
                            Button("Connect") { model.connect(profileID: profile.id) }
                            Button("Edit…") {
                                model.selectedProfileID = profile.id
                                model.beginEditingSelectedProfile()
                            }
                            Button("Duplicate") {
                                model.selectedProfileID = profile.id
                                model.duplicateSelectedProfile()
                            }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                model.selectedProfileID = profile.id
                                model.requestDeleteSelectedProfile()
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search servers")
        .onKeyPress(.return) {
            guard model.selectedProfileID != nil else { return .ignored }
            model.connectSelected()
            return .handled
        }
        .accessibilityLabel("Saved servers")
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    model.beginCreatingProfile()
                } label: {
                    Label("Add Server", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Add server profile")
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct ProfileRow: View {
    let profile: ConnectionProfile
    @ObservedObject private var sessionBox: SessionBox
    @State private var isHovered = false

    init(profile: ConnectionProfile, session: TerminalViewModel?) {
        self.profile = profile
        self.sessionBox = SessionBox(session: session)
    }

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text("\(profile.username)@\(profile.host)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName), \(profile.username) at \(profile.host), \(statusDescription)")
        .accessibilityHint("Click to select, double-click or press Return to connect")
    }

    private var state: TerminalViewModel.State? { sessionBox.session?.state }

    private var statusDescription: String {
        switch state {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .failed: return "connection failed"
        default: return "not connected"
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var dotColor: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        default: return Color.secondary.opacity(0.4)
        }
    }
}

/// Lets a row observe its session's published state when one exists.
final class SessionBox: ObservableObject {
    let session: TerminalViewModel?
    init(session: TerminalViewModel?) {
        self.session = session
        if let session {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }
    private var cancellables = Set<AnyCancellable>()
}

import Combine
