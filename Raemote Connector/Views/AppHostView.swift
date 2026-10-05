import SafariServices
import SwiftUI

/// The single presented-app screen.
///
/// The app on screen is `sessionManager.activeKey` — **not** the navigation
/// route. Its page lives in the session's warm tab controller
/// (`WebAppTabRack`), mounted here for as long as the screen is up: switching
/// apps swaps the visible tab instantly with state preserved, and **Done**
/// (or the edge-swipe) pops the screen while every tab keeps running — Safari
/// owns its chrome (back/forward/reload/share), this screen only supplies
/// what Safari can't: waiting for a live iroh connection, starting the
/// proxy, and treating Done as "leave the app".
struct AppHostView: View {
    let sessionManager: WebAppSessionManager
    let irohService: IrohService
    let monitor: IrohConnectionMonitor

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Why the loopback proxy could not start, when it could not.
    @State private var proxyError: String?

    var body: some View {
        Group {
            if let key = sessionManager.activeKey,
               let session = sessionManager.session(for: key) {
                content(key: key, session: session)
            } else {
                // The presented app is gone — closed from a list, its server
                // removed, or its session dropped. Leave instead of resurrecting
                // it (the view never opens sessions itself). Its tab was
                // destroyed along with the session.
                Color.clear
                    .onAppear { dismiss() }
            }
        }
    }

    private func content(key: WebAppSessionKey, session: WebAppSession) -> some View {
        ZStack {
            // One identity for the whole screen (no `.id(key)`): switching the
            // active key only re-mounts the rack with a different visible tab,
            // which is what makes a switch instant and state-preserving. The
            // mount creates the tab from `activeURL` once the proxy is up (and
            // self-heals a memory-evicted page on re-present).
            RackMountView(
                rack: sessionManager.rack,
                activeKey: key,
                activeURL: session.proxyURL,
                // Done on the active tab: leave the screen; the session (and
                // every warm tab) keeps running.
                onFinish: { dismiss() }
            )
            // The rack hides every tab until this session's proxy is listening,
            // so a cold app shows the gate over an empty rack instead of a
            // failing origin.
            if session.proxyURL == nil {
                connectionGate(key: key, session: session)
            }
        }
        // Our navigation chrome would only compete with Safari's own bar.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // SwiftUI sizes content to stay inside the safe area by default, so
        // without this the rack only ever gets safe-area-reduced bounds and
        // the window's background shows through as white borders (home
        // indicator in portrait, notch insets in landscape). SFVC still
        // respects safe areas internally — its toolbar keeps clearing the
        // status bar/notch — because UIKit propagates them down the chain.
        .ignoresSafeArea()
        .task(id: key) {
            // Re-runs per active key (the screen's identity does not change):
            // switching apps must activate + connect for the *new* app, not
            // resume the previous one's wait. Also runs on every re-appearance —
            // the proxy may already be running.
            proxyError = nil
            sessionManager.activate(key)
            await connectThenStart(key: key, session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await irohService.validateConnection(nodeId: key.nodeId) }
        }
        .onChange(of: connectionState(for: key)) { _, newState in
            if case .connected = newState, session.proxyURL == nil {
                Task { await startProxy(key: key, session: session) }
            }
        }
        // No teardown on disappear: background sessions (and their warm tabs)
        // keep running. Stopping an app is only a list action (swipe / menu).
    }

    // MARK: - Connection gate

    @ViewBuilder
    private func connectionGate(key: WebAppSessionKey, session: WebAppSession) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to server…")
                .font(.headline)
            if let proxyError {
                Text(proxyError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Try Again") {
                    Task { await connectThenStart(key: key, session: session) }
                }
                .buttonStyle(.bordered)
            } else if case .disconnected(let reason) = connectionState(for: key),
                      let reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    /// This session's server connection state. Keyed by node id, so the host
    /// never acts on (or shows) another server's connection state.
    private func connectionState(for key: WebAppSessionKey) -> IrohConnectionState {
        monitor.state(for: key.nodeId)
    }

    /// Wait for a live connection, then bring up the loopback proxy. Retries
    /// until connected (or the task is cancelled by a key switch / the screen
    /// going away). Re-presenting a running app skips the wait: the proxy is
    /// already up.
    private func connectThenStart(key: WebAppSessionKey, session: WebAppSession) async {
        if session.proxyURL != nil {
            await irohService.validateConnection(nodeId: key.nodeId)
            return
        }
        while !Task.isCancelled {
            await irohService.validateConnection(nodeId: key.nodeId)
            if case .connected = connectionState(for: key) { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        await startProxy(key: key, session: session)
    }

    private func startProxy(key: WebAppSessionKey, session: WebAppSession) async {
        guard session.proxyURL == nil else { return }
        guard case .connected = connectionState(for: key) else { return }
        do {
            // A stored launch path (e.g. `/?token=…`) applies on first start;
            // later activations reuse the same origin.
            let launchPath = AppLaunchStore.path(nodeId: key.nodeId, app: key.app)
            _ = try await sessionManager.ensureProxy(for: session, launchPath: launchPath)
            proxyError = nil
        } catch {
            proxyError = error.localizedDescription
        }
    }
}
