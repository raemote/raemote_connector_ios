import SwiftUI

/// A plain-language explanation of what Raemote is, how it trusts devices, and
/// where to name this device.
struct AboutView: View {
    /// Node ids of the bound servers to push a renamed device name to.
    let nodeIds: [String]
    let irohService: IrohService

    @Environment(\.dismiss) private var dismiss
    @State private var deviceName: String = DeviceNameStore.name
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Reach the web apps on your own computer — from your phone.")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    section("What this app does") {
                        Text("It connects to a Raemote server on your computer and shows the web apps it finds there — Jellyfin, Home Assistant, a dev server — so you can open them anywhere.")
                    }

                    section("Your phone is a trusted device") {
                        Text("When you scan the server's pairing code, your phone and the server recognize each other by a private key kept on each device. There is no account and no password.")
                        Text("The server only accepts devices you paired. You can remove any device from the server at any time with `raemote devices revoke <id>`.")
                    }

                    deviceNameSection

                    section("Private by default") {
                        Text("The connection is end-to-end encrypted. It goes directly between your phone and computer when possible; otherwise a relay forwards the encrypted traffic without being able to read it. Nothing is exposed to the public Internet.")
                    }

                    section("If your apps don't appear") {
                        Text("Make sure they're running on the computer and answer an HTTP request. On the server, run `raemote discover`, or add one by hand with `raemote apps add myserver 8080`.")
                    }

                    Divider()

                    Text(version)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let url = URL(string: "https://github.com/raemote/raemote_server") {
                        Link("Setup guide and documentation", destination: url)
                            .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationTitle("About Raemote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { saveTask?.cancel() }
        }
    }

    private var deviceNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This device")
                .font(.headline)
            TextField("Device name", text: $deviceName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: deviceName) { _, newValue in
                    scheduleSave(newValue)
                }
            Text("Shown on your server so you can tell your devices apart when pairing or revoking them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Persist immediately, then push the name to the servers after a pause so
    /// typing doesn't fire a request per keystroke.
    private func scheduleSave(_ newValue: String) {
        DeviceNameStore.name = newValue
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await irohService.syncDeviceName(to: nodeIds, name: newValue)
        }
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Raemote Connector \(short) (\(build))"
    }
}

#Preview {
    AboutView(nodeIds: [], irohService: IrohService(monitor: IrohConnectionMonitor()))
}
