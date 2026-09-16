import SwiftUI

struct ContentView: View {
    @State private var servers: [Server] = []
    @State private var isBinding = false
    @State private var showPairingCancel = false
    @State private var bindingTask: Task<Void, Never>?
    @State private var bindingTimer: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showManualSetup = false
    @State private var showAbout = false
    @State private var uriInput = ""
    @State private var inputError: String?
    @State private var connectionMonitor: IrohConnectionMonitor
    @State private var irohService: IrohService
    @State private var path = NavigationPath()
    @State private var pendingDeepLink: DeepLink?
    /// Set once after the first successful pairing, to show the network tip.
    @State private var firstPairingName: String?

    private let storageKey = "boundServers"

    init() {
        let monitor = IrohConnectionMonitor()
        _connectionMonitor = State(initialValue: monitor)
        _irohService = State(initialValue: IrohService(monitor: monitor))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if servers.isEmpty {
                    ContentUnavailableView(
                        "No Servers Yet",
                        systemImage: "server.rack",
                        description: Text("On your computer, run “raemote pair”, then tap + and scan the QR code.")
                    )
                } else {
                    ForEach(servers) { server in
                        NavigationLink(value: server) {
                            serverRow(server)
                        }
                    }
                    .onDelete(perform: deleteServers)
                }
            }
            .navigationTitle("Raemote")
            .navigationDestination(for: Server.self) { server in
                ServerDetailView(
                    server: server,
                    irohService: irohService,
                    monitor: connectionMonitor,
                    onAppsUpdated: { apps in
                        updateServerApps(nodeId: server.nodeId, apps: apps)
                    },
                    onAliasChange: { alias in
                        updateServerAlias(nodeId: server.nodeId, alias: alias)
                    },
                    onReportedName: { name in
                        updateServerReportedName(nodeId: server.nodeId, reportedName: name)
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                            ScannerPresentation.present { QRScannerScreen() }
                        }
                        Button("Manual Setup") {
                            uriInput = ""
                            inputError = nil
                            showManualSetup = true
                        }
                        Divider()
                        Button("About Raemote", systemImage: "info.circle") {
                            showAbout = true
                        }
                    } label: {
                        if isBinding {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(isBinding)
                }
            }
            .alert("Invalid URI", isPresented: .constant(inputError != nil)) {
                Button("OK") { inputError = nil }
            } message: {
                if let inputError {
                    Text(inputError)
                }
            }
            .alert("Binding Failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .alert(
                "Connected to \(firstPairingName ?? "your server")",
                isPresented: .constant(firstPairingName != nil)
            ) {
                Button("Got it") { firstPairingName = nil }
            } message: {
                Text("You're paired — Raemote reaches this server from anywhere, with no port forwarding or VPN.\n\nIt's worth confirming in your setup: switch between Wi-Fi and cellular and open the server on each. The first connection on a new network can take a few seconds while your devices find a path to each other.")
            }
            .sheet(isPresented: $showManualSetup) {
                manualSetupSheet
            }
            .sheet(isPresented: $showAbout) {
                AboutView(nodeIds: servers.map(\.nodeId), irohService: irohService)
            }
            .onReceive(NotificationCenter.default.publisher(for: .qrScannerScanned)) { note in
                guard let uri = note.object as? String else { return }
                print("[ContentView] received scanned URI")
                uriInput = uri
                startBinding()
            }
            .overlay {
                if isBinding {
                    bindingProgressOverlay
                }
            }
            .task {
                loadServers()
                if let link = pendingDeepLink {
                    resolve(link)
                }
            }
            .onOpenURL { handleDeepLink($0) }
        }
    }

    // MARK: - Manual Setup Sheet

    private var manualSetupSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("raemote://bind?node=...&token=...", text: $uriInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Paste the raemote link from the server")
                } footer: {
                    Text("On the server, run “raemote pair” to show this link and a QR code. It looks like raemote://bind?node=…&token=…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect to Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showManualSetup = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        startBinding()
                    }
                    .disabled(uriInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Binding Progress

    private var bindingProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(showPairingCancel ? "Still connecting…" : "Connecting…")
                    .font(.headline)
                if showPairingCancel {
                    Button("Cancel Pairing", role: .cancel) {
                        cancelBinding()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Actions

    /// Parse the pasted/scanned link and start pairing.
    private func startBinding() {
        let trimmed = uriInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let (nodeId, token) = Self.parseRaemoteURI(trimmed) else {
            inputError = "Could not parse URI. Make sure it starts with `raemote://bind?node=...&token=...`."
            return
        }

        showManualSetup = false
        beginBinding(nodeId: nodeId, token: token)
    }

    /// Pair in the background. There is no hard timeout: after 15s the overlay
    /// offers a Cancel Pairing button instead of failing on its own.
    private func beginBinding(nodeId: String, token: String) {
        guard !isBinding else { return }
        isBinding = true
        showPairingCancel = false

        let timer = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            showPairingCancel = true
        }
        bindingTimer = timer

        bindingTask = Task {
            defer {
                timer.cancel()
                isBinding = false
                showPairingCancel = false
                bindingTimer = nil
                bindingTask = nil
            }

            do {
                print("[ContentView] binding to node \(nodeId.prefix(16))...")
                try await irohService.bind(serverNodeId: nodeId, token: token)
                print("[ContentView] fetching catalog...")
                let apps = try await irohService.fetchCatalog()
                print("[ContentView] got \(apps.count) app(s): \(apps.map(\.name))")

                let existing = servers.first(where: { $0.nodeId == nodeId })
                var server = Server(
                    nodeId: nodeId,
                    name: existing?.name ?? "",
                    reportedName: existing?.reportedName,
                    apps: apps
                )
                // Ask the server for its own name (best effort).
                if let info = try? await irohService.fetchServerInfo(), !info.name.isEmpty {
                    server.reportedName = info.name
                }

                let isFirstPairing = servers.isEmpty
                if let idx = servers.firstIndex(where: { $0.nodeId == nodeId }) {
                    servers[idx] = server
                } else {
                    servers.append(server)
                }
                saveServers()

                if isFirstPairing, OnboardingStore.shouldShowNetworkTip() {
                    OnboardingStore.markNetworkTipShown()
                    firstPairingName = server.displayName
                }
            } catch is CancellationError {
                // The user cancelled pairing; no error to show.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Abort an in-flight pairing (also called from the overlay's button).
    private func cancelBinding() {
        bindingTimer?.cancel()
        bindingTask?.cancel()
        bindingTimer = nil
        bindingTask = nil
        isBinding = false
        showPairingCancel = false
    }

    private func serverRow(_ server: Server) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.displayName)
                .font(.headline)
            if !server.name.trimmingCharacters(in: .whitespaces).isEmpty,
               let reported = server.reportedName, !reported.isEmpty {
                Text(reported)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(server.nodeId.prefix(16) + "...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(server.apps.count) app\(server.apps.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - URI Parser

    static func parseRaemoteURI(_ uri: String) -> (nodeId: String, token: String)? {
        guard let url = URL(string: uri),
              url.scheme == "raemote",
              url.host == "bind",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let node = items.first(where: { $0.name == "node" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              !node.isEmpty,
              !token.isEmpty
        else { return nil }
        return (node, token)
    }

    // MARK: - Persistence

    private func deleteServers(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        saveServers()
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Server].self, from: data)
        else { return }
        servers = decoded
    }

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - Deep links

    /// Handle a `raemote://` URL. The `raemote` scheme is registered in
    /// `Info.plist`, so iOS launches the app for a matching link.
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        pendingDeepLink = link
        resolve(link)
    }

    /// Navigate to a deep link's server (and app, when it is cached). Keeps the
    /// link pending if the server isn't bound yet, so it can be resolved after
    /// the stored servers load.
    private func resolve(_ link: DeepLink) {
        guard let nodeId = link.nodeId,
              let server = servers.first(where: { $0.nodeId == nodeId }) else {
            return
        }
        var newPath = NavigationPath()
        newPath.append(server)
        if let appName = link.appName,
           let app = server.apps.first(where: { $0.name == appName }) {
            newPath.append(app)
        }
        pendingDeepLink = nil
        path = newPath
    }

    /// Persist a refreshed app list coming back from `ServerDetailView`.
    private func updateServerApps(nodeId: String, apps: [AppInfo]) {
        guard let index = servers.firstIndex(where: { $0.nodeId == nodeId }) else { return }
        servers[index].apps = apps
        saveServers()
    }

    /// Persist the user's alias for a server.
    private func updateServerAlias(nodeId: String, alias: String) {
        guard let index = servers.firstIndex(where: { $0.nodeId == nodeId }) else { return }
        servers[index].name = alias
        saveServers()
    }

    /// Persist the name the server reports about itself.
    private func updateServerReportedName(nodeId: String, reportedName: String) {
        guard let index = servers.firstIndex(where: { $0.nodeId == nodeId }) else { return }
        guard servers[index].reportedName != reportedName else { return }
        servers[index].reportedName = reportedName
        saveServers()
    }
}

#Preview {
    ContentView()
}
