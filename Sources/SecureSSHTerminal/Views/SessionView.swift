import SwiftUI
import SecureSSHCore

/// Terminal area for one session, with a status bar and state overlays.
struct SessionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalViewModel

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            ZStack {
                TerminalHostView(session: session)
                    .accessibilityLabel("Terminal for \(session.profile.displayName)")
                overlay
                copyToast
            }
        }
        .background(Color.black)
    }

    /// Transient confirmation shown after copy-on-select.
    @ViewBuilder
    private var copyToast: some View {
        VStack {
            if let notice = model.copyNotice {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Copied \(notice.characterCount) character\(notice.characterCount == 1 ? "" : "s")")
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(notice.id)
                .accessibilityLabel("Copied \(notice.characterCount) characters to the clipboard")
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: model.copyNotice)
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            statusPill
            Text("\(session.profile.username)@\(session.profile.host):\(String(session.profile.port))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            if session.state == .connected {
                Button {
                    Task { await session.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .accessibilityLabel("Disconnect session")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(statusColor.opacity(0.15)))
        .accessibilityLabel("Session status: \(statusText)")
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected, .idle: return .gray
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(session.profile.host)…")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.yellow)
                Text("Connection Failed")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .textSelection(.enabled)
                Button("Retry") {
                    model.connect(profileID: session.profile.id)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Retry connection")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .disconnected(let reason):
            VStack(spacing: 12) {
                Image(systemName: "bolt.slash.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("Session Ended")
                    .font(.headline)
                if let reason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Reconnect") {
                    model.connect(profileID: session.profile.id)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Reconnect")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .idle, .connected:
            EmptyView()
        }
    }
}
