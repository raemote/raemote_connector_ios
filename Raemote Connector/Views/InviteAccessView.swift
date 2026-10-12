import SwiftUI

/// The invite-access picker, shown *before* an invitation is minted.
///
/// The inviter chooses between "the new device gets exactly what this device
/// has" (the classic bodyless invite) and a narrowed invitation that only
/// opens the selected apps' ports — then the sheet swaps to the QR once the
/// mint succeeds.
///
/// Selection is per *app*, but the server's allowlist is per origin **port**
/// (a documented boundary), so apps sharing a port are granted together: the
/// footer always shows the resolved port list, plus any unchecked app that
/// comes along with it, so the UI never implies granularity the server
/// doesn't have.
struct InviteAccessView: View {
    /// The apps this device can currently see (re-filtered against the
    /// freshly reported scope before display).
    let apps: [AppInfo]
    /// This device's own access scope, as reported by `GET /_hub/info`.
    let access: DeviceAccess?
    /// The server the invitation belongs to (for `AppIconView` fetching).
    let nodeId: String
    /// Icon fetching for the app rows (cached, same store as the app list).
    let irohService: IrohService
    /// An invitation is being minted; the Create button spins and Cancel is
    /// locked so the sheet can't be torn down mid-mint.
    let isMinting: Bool
    /// Mint failure (e.g. the server's `beyond_grant`), shown inline — the
    /// sheet covers the screen, so the root view's alert can't be seen.
    let errorMessage: String?
    /// Mint the invitation: `nil` inherits this device's access, a port list
    /// narrows it. The server re-checks either way.
    let onCreate: ([UInt16]?) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Whether "Only some apps…" is the active choice.
    @State private var limited = false
    /// Names of the checked apps.
    @State private var checked: Set<String> = []

    /// The apps offered in the picker — never wider than this device's
    /// reported scope, even if the stored catalog is stale.
    private var selectableApps: [AppInfo] {
        InviteAccess.selectableApps(access: access, apps: apps)
    }

    private var grantPorts: [UInt16] {
        InviteAccess.grantedPorts(apps: apps, selected: checked)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choiceRow(
                        selected: !limited,
                        title: "Same as this device",
                        subtitle: inheritCaption
                    ) {
                        limited = false
                    }
                    choiceRow(
                        selected: limited,
                        title: "Only some apps…",
                        subtitle: limitedCaption
                    ) {
                        // Start from "everything visible", so limiting is a
                        // matter of unchecking rather than hunting.
                        if checked.isEmpty {
                            checked = Set(selectableApps.map(\.name))
                        }
                        limited = true
                    }
                    .disabled(selectableApps.isEmpty || isMinting)
                } footer: {
                    Text("The invited device can never get more than this device has.")
                }

                if limited {
                    Section {
                        ForEach(selectableApps) { app in
                            Button {
                                if checked.contains(app.name) {
                                    checked.remove(app.name)
                                } else {
                                    checked.insert(app.name)
                                }
                            } label: {
                                appRow(app, selected: checked.contains(app.name))
                            }
                            .buttonStyle(.plain)
                            .disabled(isMinting)
                        }
                    } header: {
                        Text("Apps to open")
                    } footer: {
                        Text(grantSummary)
                    }
                }

                Section {
                    Button {
                        onCreate(limited ? grantPorts : nil)
                    } label: {
                        HStack {
                            Text("Create Invitation")
                            Spacer()
                            if isMinting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isMinting || (limited && grantPorts.isEmpty))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Invite Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isMinting)
                }
            }
            // A swipe-down mid-mint would discard a link the server already
            // created; the mint is short, so hold the sheet until it lands.
            .interactiveDismissDisabled(isMinting)
        }
    }

    // MARK: - Rows

    private func choiceRow(
        selected: Bool,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMinting)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func appRow(_ app: AppInfo, selected: Bool) -> some View {
        HStack(spacing: 10) {
            AppIconView(nodeId: nodeId, app: app.name, service: irohService)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(app.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Copy

    private var inheritCaption: String {
        switch access {
        case .some(.all):
            return "Opens every app on this server, including ones added later."
        case .some(.ports(let ports)):
            if ports.isEmpty { return "This device has no apps to grant." }
            let list = ports.sorted().map(String.init).joined(separator: ", ")
            return "Exactly this device's access: ports \(list)."
        case nil:
            return "Exactly the access this device has."
        }
    }

    private var limitedCaption: String {
        if selectableApps.isEmpty { return "No apps are available to restrict to." }
        return "Only the apps you pick below."
    }

    private var grantSummary: String {
        guard !grantPorts.isEmpty else { return "Nothing selected yet." }
        let list = grantPorts.map(String.init).joined(separator: ", ")
        var lines = ["Will grant ports \(list)."]
        let along = InviteAccess.alsoGrantedApps(apps: apps, selected: checked)
        if !along.isEmpty {
            let names = along.map(\.name).joined(separator: ", ")
            lines.append("Also opens \(names) — apps sharing a granted port are allowed together.")
        }
        return lines.joined(separator: " ")
    }
}

#Preview {
    InviteAccessView(
        apps: [
            AppInfo(name: "appA", path: "/", port: 18300),
            AppInfo(name: "appB", path: "/", port: 18800),
            AppInfo(name: "appC", path: "/", port: 18800),
        ],
        access: .all,
        nodeId: "abc",
        irohService: IrohService(monitor: IrohConnectionMonitor()),
        isMinting: false,
        errorMessage: nil,
        onCreate: { _ in }
    )
}
