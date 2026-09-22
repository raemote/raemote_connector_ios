import SwiftUI

/// The list's "Recent" row: every app the user has opened, most recent first,
/// as a single horizontally scrolling strip of capsule chips — the app's
/// circular icon beside its name, one tap to open.
///
/// A running app carries a green dot on its icon; a stopped one is still here —
/// that is the point of the section — and tapping it launches a fresh session.
/// It replaces the old full-height "Running" list, so a long history costs one
/// row of screen space instead of many.
struct RecentAppsSection: View {
    let entries: [RecentAppStore.Entry]
    let servers: [Server]
    let sessionManager: WebAppSessionManager
    let irohService: IrohService
    let onOpen: (WebAppSessionKey) -> Void

    private let iconSize: CGFloat = 28
    private let chipSpacing: CGFloat = 10
    /// Cap a chip's name so one long app name can't push every other chip off
    /// screen; it truncates instead.
    private let maxNameWidth: CGFloat = 132

    var body: some View {
        Section("Recent") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: chipSpacing) {
                    ForEach(entries) { entry in
                        chip(entry)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        }
    }

    private func chip(_ entry: RecentAppStore.Entry) -> some View {
        let key = entry.key
        let running = sessionManager.isRunning(key)
        let name = AppNameStore.name(nodeId: key.nodeId, app: key.app) ?? key.app
        let serverName = servers.first { $0.nodeId == key.nodeId }?.displayName
        return Button {
            onOpen(key)
        } label: {
            HStack(spacing: 8) {
                AppIconView(nodeId: key.nodeId, app: key.app, service: irohService, size: iconSize)
                    .overlay(alignment: .topTrailing) {
                        if running {
                            Circle()
                                .fill(.green)
                                .frame(width: 9, height: 9)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color(uiColor: .secondarySystemGroupedBackground),
                                        lineWidth: 1.5
                                    )
                                )
                                .offset(x: 2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxNameWidth, alignment: .leading)
            }
            // The icon (a 28 pt circle, inset 6 pt) is concentric with the
            // capsule's left cap (radius 20 = 6 + 14), so the two read as one
            // shape rather than a circle floating in a pill.
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color(uiColor: .tertiarySystemFill)))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? "\(name), running" : name)
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
    return List {
        RecentAppsSection(
            entries: [
                .init(nodeId: "server-a", app: "jellyfin", lastUsed: .now),
                .init(nodeId: "server-a", app: "grafana", lastUsed: .now),
                .init(nodeId: "server-b", app: "home-assistant", lastUsed: .now),
                .init(nodeId: "server-a", app: "pihole", lastUsed: .now),
                .init(nodeId: "server-a", app: "very-long-application-name-here", lastUsed: .now),
            ],
            servers: [],
            sessionManager: manager,
            irohService: service,
            onOpen: { _ in }
        )
    }
}
