import SwiftUI

/// A pushable route for a web app, registered at the ROOT of the navigation
/// stack so the running-apps list (and any cross-session switch) can present
/// the app directly — without first walking through the server's detail view.
/// Distinct from `AppInfo` (whose destination lives inside `ServerDetailView`)
/// so both can coexist in one stack without colliding destinations.
struct RunningAppRoute: Hashable {
    let nodeId: String
    let app: String
    /// Upstream app port, display only (`0` when unknown/offline).
    let port: Int
}

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
    /// Registry of simultaneously running web apps (cap 5, LRU eviction);
    /// sessions keep running when the user navigates away from them.
    @State private var sessionManager: WebAppSessionManager
    @State private var path = NavigationPath()
    @State private var pendingDeepLink: DeepLink?
    /// Set once after the first successful pairing, to show the network tip.
    @State private var firstPairingName: String?

    private let storageKey = "boundServers"

    init() {
        let monitor = IrohConnectionMonitor()
        let service = IrohService(monitor: monitor)
        _connectionMonitor = State(initialValue: monitor)
        _irohService = State(initialValue: service)
        _sessionManager = State(initialValue: WebAppSessionManager(service: service))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Live running apps across all paired servers; tap to resume
                // (warm), swipe to close the session (site data is kept).
                if !sessionManager.running.isEmpty {
                    runningSection
                }
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
            .navigationDestination(for: RunningAppRoute.self) { route in
                appRouteView(route)
            }
            .navigationDestination(for: Server.self) { server in
                ServerDetailView(
                    server: server,
                    irohService: irohService,
                    monitor: connectionMonitor,
                    sessionManager: sessionManager,
                    onAppsUpdated: { apps in
                        updateServerApps(nodeId: server.nodeId, apps: apps)
                    },
                    onAliasChange: { alias in
                        updateServerAlias(nodeId: server.nodeId, alias: alias)
                    },
                    onReportedName: { name in
                        updateServerReportedName(nodeId: server.nodeId, reportedName: name)
                    },
                    onSwitchSession: { key in
                        openRunningSession(key)
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
            .alert("Pair to this server?", isPresented: .constant(pendingPairing != nil)) {
                Button("Pair") {
                    if let pending = pendingPairing {
                        pendingPairing = nil
                        beginBinding(nodeId: pending.nodeId, token: pending.token)
                    }
                }
                Button("Cancel", role: .cancel) { pendingPairing = nil }
            } message: {
                Text("This will connect to the server whose identity ends in …\(pendingPairing?.nodeId.suffix(8) ?? ""). Only continue if you scanned the QR from your own machine or got its link directly.")
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

    /// A parsed pairing URI awaiting the user's confirmation. Pairing must
    /// never start without showing which node the user is about to trust: a
    /// decoy QR/link otherwise enrolls the phone on an attacker's server
    /// silently (target identity only appears after a successful bind).
    @State private var pendingPairing: (nodeId: String, token: String)?

    /// Parse the pasted/scanned link and stage pairing for confirmation.
    private func startBinding() {
        let trimmed = uriInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let (nodeId, token) = Self.parseRaemoteURI(trimmed) else {
            inputError = "Could not parse URI. Make sure it starts with `raemote://bind?node=...&token=...`."
            return
        }

        showManualSetup = false
        pendingPairing = (nodeId: nodeId, token: token)
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
                let apps = try await irohService.fetchCatalog(nodeId: nodeId)
                print("[ContentView] got \(apps.count) app(s): \(apps.map(\.name))")

                let existing = servers.first(where: { $0.nodeId == nodeId })
                var server = Server(
                    nodeId: nodeId,
                    name: existing?.name ?? "",
                    reportedName: existing?.reportedName,
                    apps: apps
                )
                // Ask the server for its own name (best effort).
                if let info = try? await irohService.fetchServerInfo(nodeId: nodeId), !info.name.isEmpty {
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

    /// The "Running" section in the server list: live sessions across every
    /// paired server, tap to resume, swipe to close.
    private var runningSection: some View {
        let sessions = sessionManager.running
        return Section("Running") {
            ForEach(sessions, id: \.key) { session in
                runningRow(session)
            }
            .onDelete { offsets in
                closeRunningSessions(at: offsets)
            }
        }
    }

    private func closeRunningSessions(at offsets: IndexSet) {
        let sessions = sessionManager.running
        for offset in offsets where offset < sessions.count {
            sessionManager.close(sessions[offset].key)
        }
    }

    /// A running app row: green dot + app name + server name; tap resumes the
    /// warm session via the root-level route (same presenter the strip and the
    /// detail view use); long-press closes it.
    private func runningRow(_ session: WebAppSession) -> some View {
        let key = session.key
        let route = routeFor(key)
        let appName = AppNameStore.name(nodeId: key.nodeId, app: key.app) ?? key.app
        let server = servers.first { $0.nodeId == key.nodeId }
        let serverName = server?.displayName ?? String(key.nodeId.prefix(12)) + "…"
        return NavigationLink(value: route) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("Running")
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName).font(.headline)
                    Text(serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button("Close App", role: .destructive) {
                sessionManager.close(key)
            }
        }
    }

    /// Resolve the root-level push route for a session key; the port comes
    /// from the server's catalog when it still has the app (display only).
    private func routeFor(_ key: WebAppSessionKey) -> RunningAppRoute {
        let server = servers.first { $0.nodeId == key.nodeId }
        let port = server?.apps.first { $0.name == key.app }?.port
        return RunningAppRoute(nodeId: key.nodeId, app: key.app, port: port ?? 0)
    }

    /// The presenter for a root-level running-app route. The web view itself
    /// persists learned names in `AppNameStore`; the list rows read them on
    /// rebuild, so the name callback here is a no-op.
    private func appRouteView(_ route: RunningAppRoute) -> some View {
        let launchPath = AppLaunchStore.path(nodeId: route.nodeId, app: route.app)
        let app = AppInfo(name: route.app, path: "", port: route.port)
        return AppWebView(
            app: app,
            nodeId: route.nodeId,
            irohService: irohService,
            monitor: connectionMonitor,
            sessionManager: sessionManager,
            launchPath: launchPath,
            onNameLearned: { _ in
                // no local state to update at the root level
            },
            onSwitchSession: { key in
                openRunningSession(key)
            }
        )
    }

    /// Present a running (or newly opened) session: swap the whole stack to
    /// the root-level app route. The previously presented session stays warm;
    /// this only changes focus. Deterministic — no destination-registration
    /// timing (the route's destination is registered at the root).
    private func openRunningSession(_ key: WebAppSessionKey) {
        sessionManager.activate(key)
        path = NavigationPath()
        path.append(routeFor(key))
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
        let removed = offsets.map { servers[$0] }
        servers.remove(atOffsets: offsets)
        saveServers()
        // Sessions of a deleted server would keep dialing a node the user no
        // longer has a list entry for: close them too.
        for server in removed {
            sessionManager.closeRunningSessions(nodeId: server.nodeId)
        }
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
