import SwiftUI

/// The **Recent** tab: every app the user has opened, most recent first, one
/// line each. A running app carries a green dot on its icon; a stopped one is
/// still here — that is the point of the tab — and tapping it launches a fresh
/// session.
///
/// This used to be a horizontal strip of capsule chips squeezed above the
/// server list. With a tab of its own it can be a plain list, which is what a
/// long history deserves: one line per app, and no sideways scrolling.
struct RecentAppsView: View {
    let entries: [RecentAppStore.Entry]
    let servers: [Server]
    let sessionManager: WebAppSessionManager
    let irohService: IrohService
    let onOpen: (WebAppSessionKey) -> Void

    private let iconSize: CGFloat = 32

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Recent Apps",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Apps you open from a server show up here, ready to reopen with one tap.")
                )
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        }
    }

    /// One line: icon, app name, and the server it lives on as a quiet
    /// trailing label (two apps can share a name across servers).
    private func row(_ entry: RecentAppStore.Entry) -> some View {
        let key = entry.key
        let running = sessionManager.isRunning(key)
        let serverName = servers.first { $0.nodeId == key.nodeId }?.displayName
        return Button {
            onOpen(key)
        } label: {
            HStack(spacing: 10) {
                AppIconView(nodeId: key.nodeId, app: key.app, service: irohService, size: iconSize)
                    .overlay(alignment: .topTrailing) {
                        if running {
                            Circle()
                                .fill(.green)
                                .frame(width: 10, height: 10)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color(uiColor: .secondarySystemGroupedBackground),
                                        lineWidth: 2
                                    )
                                )
                                .offset(x: 2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
                Text(key.app)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let serverName {
                    Text(serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? "\(key.app), running" : key.app)
        .accessibilityHint(serverName.map { "on \($0)" } ?? "")
        .contextMenu {
            if running {
                Button("Close App", role: .destructive) {
                    // Stop the app; the recent entry stays (no green dot).
                    sessionManager.close(key)
                }
            }
            Button("Remove from Recents", role: .destructive) {
                RecentAppStore.shared.remove(key)
            }
        }
    }
}

#Preview {
    let service = IrohService(monitor: IrohConnectionMonitor())
    let manager = WebAppSessionManager(service: service)
    // One running (green dot), the rest stopped.
    _ = manager.open(nodeId: "server-a", app: "jellyfin")
    return RecentAppsView(
        entries: [
            .init(nodeId: "server-a", app: "jellyfin", lastUsed: .now),
            .init(nodeId: "server-a", app: "grafana", lastUsed: .now),
            .init(nodeId: "server-b", app: "home-assistant", lastUsed: .now),
            .init(nodeId: "server-a", app: "very-long-application-name-here", lastUsed: .now),
        ],
        servers: [
            Server(nodeId: "server-a", name: "Mac mini"),
            Server(nodeId: "server-b", name: "Raspberry Pi"),
        ],
        sessionManager: manager,
        irohService: service,
        onOpen: { _ in }
    )
}
