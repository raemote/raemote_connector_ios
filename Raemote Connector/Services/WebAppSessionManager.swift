import Observation
import SwiftUI
import WebKit

/// How a running web app is identified: one server node + one catalog app.
/// Everything the session owns (proxy port, web view, page state) is bound to
/// this pair; two servers can run an identically-named app without ever
/// sharing state (the NodeId-isolation rule).
struct WebAppSessionKey: Hashable, Identifiable, Sendable {
    let nodeId: String
    let app: String

    var id: String { "\(nodeId)/\(app)" }
}

/// One background web app: a bound loopback `LocalProxyServer` and one
/// long-lived `WKWebView`. Leaving the presenter keeps the session running
/// (tunnel up, page state warm); "Close" is the only thing that ends one.
@MainActor
@Observable
final class WebAppSession {
    let key: WebAppSessionKey
    /// The stable loopback origin once the proxy is listening.
    var proxyURL: URL?
    /// Session-scoped page state (loading/error/history flags), so switching
    /// apps keeps each page's own spinner or banner.
    let state = WebViewState()
    /// The session's web view, strongly owned by the session so it survives
    /// being detached from the view hierarchy (a `weak` reference would drop
    /// it the moment the presenter goes away — and a re-present would then
    /// build a fresh, blank one). Created once by the presenter; nulled only
    /// by `close`.
    @ObservationIgnored var webView: WKWebView?
    /// Source of the LRU eviction ordering.
    @ObservationIgnored var lastActivated: Date = .distantPast

    fileprivate var proxy: LocalProxyServer?
    /// Set while the first `start()` is in flight, so a burst of presenters
    /// doesn't race two listeners onto one origin.
    fileprivate var startingProxy = false
    /// The first meaningful page title has been recorded (title capture is
    /// once per session, not per presentation).
    @ObservationIgnored var capturedTitle = false
    /// The URL the shared web view was last pointed at. The session (not the
    /// per-representation coordinator) owns this, so re-presenting a warm
    /// session skips the reload and pages resume exactly where they were.
    @ObservationIgnored var lastLoadedURL: URL?

    init(key: WebAppSessionKey) {
        self.key = key
    }

    func touch() {
        lastActivated = .now
    }
}

/// Registry of simultaneously running web apps across paired servers.
///
/// - One session per `(nodeId, app)`: the same app on two servers is two
///   sessions (NodeId-isolated — this is the resource-isolation rule).
/// - Sessions are capped: launching beyond the cap evicts the least-recently
///   *used* one (proxy stopped, web view discarded; site data survives in the
///   persistent data store). Usage — not insertion order — decides, so the five
///   apps you touched most recently are the five that stay warm. Eviction is
///   only ever about memory: the app's "Recent" tile is untouched
///   (`RecentAppStore`), so it stays one tap away.
/// - Sessions live for the app's process lifetime; no cross-relaunch state.
@MainActor
@Observable
final class WebAppSessionManager {
    /// Max simultaneously running apps. Each WKWebView is a render process;
    /// past this point the system starts killing the app under memory
    /// pressure.
    static let maxSessions = 5

    private var sessions: [WebAppSessionKey: WebAppSession] = [:]
    /// Insertion-ordered keys (oldest first) for stable listing + LRU eviction.
    @ObservationIgnored private var order: [WebAppSessionKey] = []
    private(set) var activeKey: WebAppSessionKey?

    private let service: IrohService

    init(service: IrohService) {
        self.service = service
    }

    var runningCount: Int { sessions.count }

    /// All running sessions oldest-first (for the list UIs / strip).
    var running: [WebAppSession] {
        orderFilter()
    }

    func session(for key: WebAppSessionKey) -> WebAppSession? {
        sessions[key]
    }

    func isRunning(nodeId: String, app: String) -> Bool {
        isRunning(WebAppSessionKey(nodeId: nodeId, app: app))
    }

    func isRunning(_ key: WebAppSessionKey) -> Bool {
        sessions[key] != nil
    }

    /// Get (or create) this app's session. The proxy starts separately (the
    /// presenter does it once a live connection exists).
    func open(nodeId: String, app: String) -> WebAppSession {
        let key = WebAppSessionKey(nodeId: nodeId, app: app)
        if let existing = sessions[key] {
            existing.touch()
            return existing
        }
        evictIfNeeded()
        let session = WebAppSession(key: key)
        sessions[key] = session
        orderAppend(key)
        print("[Sessions] opened \(key.id); \(sessions.count) running")
        return session
    }

    /// Mark `key` the presented session (strip ordering + status sampling).
    func activate(_ key: WebAppSessionKey) {
        guard sessions[key] != nil else { return }
        activeKey = key
        sessions[key]?.touch()
    }

    func isActive(_ key: WebAppSessionKey) -> Bool {
        activeKey == key && sessions[key] != nil
    }

    /// Start (or reuse) the session's loopback proxy. `launchPath` applies on
    /// first start only; later activations resume where the page already is.
    func ensureProxy(for session: WebAppSession, launchPath: String?) async throws -> URL {
        if let url = session.proxyURL { return url }
        guard !session.startingProxy else {
            throw IrohError.connectionFailed("proxy start already in flight")
        }
        session.startingProxy = true
        defer { session.startingProxy = false }
        // Install the launch's loopback-gate secret *before* any suspension
        // that the life fence guards — the cookie doesn't depend on the port,
        // and leaving it after the fence would open a gap where a close during
        // the await lets us set proxyURL on a session that is already gone.
        await ProxyAuth.installCookie()
        let server = LocalProxyServer(
            nodeId: session.key.nodeId,
            appName: session.key.app,
            service: service,
            preferredPort: ProxyPortStore.preferredPort(nodeId: session.key.nodeId, app: session.key.app)
        )
        let port = try await server.start()
        // Life fence: the session may have been closed (or LRU-evicted) while
        // the listener was coming up. Dropping the session entry before the
        // start resolves would otherwise leave the NWListener running with no
        // owner — stop it here and refuse the install.
        guard sessions[session.key] === session else {
            server.stop()
            print("[Sessions] abandoned proxy start for closed \(session.key.id)")
            throw IrohError.connectionFailed("app was closed while starting")
        }
        ProxyPortStore.remember(port, nodeId: session.key.nodeId, app: session.key.app)
        session.proxy = server
        // WKWebView talks to this loopback proxy, which relays over iroh to
        // the raemote server. The launch path (e.g. `/?token=…`) encodes on
        // first run only. The cookie was installed above, before this URL can
        // ever be handed to the web view.
        guard let url = URL(string: "http://127.0.0.1:\(port)\(launchPath ?? "/")") else {
            server.stop()
            session.proxy = nil
            throw IrohError.connectionFailed("invalid launch path")
        }
        session.proxyURL = url
        print("[Sessions] proxy for \(session.key.id) on 127.0.0.1:\(port)")
        return url
    }

    /// Close a running app: stop its loopback proxy and discard the WKWebView.
    /// Site data (cookies/localStorage) is deliberately kept: the stable
    /// origin survives across future runs through `ProxyPortStore`.
    ///
    /// Closing the *active* session clears `activeKey`, which is how the
    /// presented app host learns to leave instead of resurrecting it.
    func close(_ key: WebAppSessionKey) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        orderRemove(key)
        if activeKey == key {
            activeKey = nil
        }
        session.proxy?.stop()
        session.proxy = nil
        session.webView?.navigationDelegate = nil
        session.webView?.uiDelegate = nil
        session.webView?.removeFromSuperview()
        session.webView = nil
        session.state.webView = nil
        session.proxyURL = nil
        print("[Sessions] closed \(key.id); \(sessions.count) running")
    }

    @discardableResult
    func close(nodeId: String, app: String) -> Bool {
        let key = WebAppSessionKey(nodeId: nodeId, app: app)
        let existed = isRunning(key)
        if existed { close(key) }
        return existed
    }

    /// Close every running session of one server (used when a paired server
    /// is removed from the device list). Returns the closed keys.
    @discardableResult
    func closeRunningSessions(nodeId: String) -> [WebAppSessionKey] {
        let keys = sessions.keys.filter { $0.nodeId == nodeId }
        for key in keys {
            close(key)
        }
        return keys
    }

    func closeAll() {
        for key in Array(sessions.keys) { close(key) }
    }

    /// Evict the least-recently-used sessions down to one free slot so a new
    /// open fits; the active session is never evicted.
    private func evictIfNeeded() {
        while sessions.count >= Self.maxSessions, let lru = leastRecentlyUsed() {
            print("[Sessions] LRU evicting \(lru.id)")
            close(lru)
        }
    }

    /// The least recently *activated* session that may be evicted, or nil when
    /// only the active session is left.
    ///
    /// Ordered by `lastActivated`, not by insertion: an app opened long ago but
    /// used a moment ago is exactly the one to keep warm — that is what "the
    /// five most recently used stay in memory" means. A session opened but not
    /// yet activated (never touched) sorts first, which is also right.
    private func leastRecentlyUsed() -> WebAppSessionKey? {
        let candidates = sessions.filter { $0.key != activeKey }
        return candidates.min { $0.value.lastActivated < $1.value.lastActivated }?.key
    }

    // MARK: - Order bookkeeping (insertion-ordered keys, oldest first)

    private func orderAppend(_ key: WebAppSessionKey) {
        order.append(key)
    }

    private func orderRemove(_ key: WebAppSessionKey) {
        order.removeAll { $0 == key }
    }

    private func orderFilter() -> [WebAppSession] {
        // Snapshot `sessions` so the observation system always tracks it.
        // When `order` is empty the compactMap never calls the closure,
        // which means `sessions` would go unobserved and the Running
        // section would never refresh.
        let snap = sessions
        return order.compactMap { snap[$0] }
    }
}
