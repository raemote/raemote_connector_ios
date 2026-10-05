import Foundation
import IrohLib

enum IrohError: LocalizedError {
    case bindDenied(String)
    case connectionFailed(String)
    case httpError(Int, String)
    case decodeFailed(String)
    case keyStoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .bindDenied(let reason): return "The server rejected pairing: \(reason)"
        case .connectionFailed(let msg): return "Couldn't connect: \(msg)"
        case .httpError(let code, let message): return "\(message) (HTTP \(code))"
        case .decodeFailed(let msg): return "Unexpected response from the server: \(msg)"
        case .keyStoreFailed(let msg): return "Couldn't store this device's key securely: \(msg)"
        }
    }

    /// Build an error from a non-2xx response, preferring the server's
    /// structured `{ "error", "hint" }` over the raw body.
    static func http(status: Int, body: Data) -> IrohError {
        struct ServerError: Decodable {
            let error: String
            let hint: String?
        }
        if let server = try? JSONDecoder().decode(ServerError.self, from: body) {
            if let hint = server.hint, !hint.isEmpty {
                return .httpError(status, "\(server.error) — \(hint)")
            }
            return .httpError(status, server.error)
        }
        let raw = String(decoding: body, as: UTF8.self)
        return .httpError(status, raw.isEmpty ? "The request failed." : raw)
    }
}

/// High-level reachability of the serve connection, surfaced in the UI.
enum IrohConnectionState: Equatable, Sendable {
    case unknown
    case connecting
    case connected
    case disconnected(String?)
}

/// Observable mirror of the iroh serve connection, updated by `IrohService`.
///
/// `IrohService` is an actor and can't be observed directly by SwiftUI, so it
/// pushes state changes into this main-actor model.
///
/// State is **per server node** (the key is the node id). A single shared value
/// would let a connected server's state be shown for a different, unreachable
/// one — the NodeId-isolation rule: connection state belongs to the server it
/// describes and is never leaked across servers.
@MainActor
@Observable
final class IrohConnectionMonitor {
    private(set) var states: [String: IrohConnectionState] = [:]
    /// Where state transitions are recorded (injectable so tests never share
    /// the app-wide buffer).
    private let log: ConnectionLog

    init(log: ConnectionLog? = nil) {
        // `nil` in the default argument (default args evaluate outside the
        // main actor, where `.shared` is unusable).
        self.log = log ?? .shared
    }

    /// The state recorded for `nodeId`, or `.unknown` when nothing is known.
    func state(for nodeId: String) -> IrohConnectionState {
        states[nodeId] ?? .unknown
    }

    /// Record `state` for `nodeId`. An actual *change* is appended to the
    /// connection log as a transition; a no-op write is not.
    func setState(_ state: IrohConnectionState, for nodeId: String) {
        let previous = states[nodeId] ?? .unknown
        guard previous != state else { return }
        states[nodeId] = state
        log.append(
            "state: \(Self.describe(previous)) → \(Self.describe(state))",
            nodeId: nodeId
        )
    }

    /// Forget every server's state (the endpoint was torn down).
    func reset() {
        states.removeAll()
    }

    private static func describe(_ state: IrohConnectionState) -> String {
        switch state {
        case .unknown: "unknown"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected(let reason): reason.map { "disconnected(\($0))" } ?? "disconnected"
        }
    }
}

/// Whether a cached serve connection may be reused without reconnecting.
///
/// A connection idle past `staleAfter` is **not trusted**: the server process
/// may have restarted since (same identity, new sockets), and QUIC will not
/// report the old connection dead until its own idle timeout (~30 s), so a
/// request would hang until then. Reconnecting is cheap; hanging is not. While
/// a stream is open the connection is demonstrably alive, so a long-lived
/// tunnel is never torn down by the window.
nonisolated enum ConnectionFreshness {
    /// How long a connection may sit idle before the client refuses to reuse it.
    /// Kept well under the QUIC idle timeout so we reconnect before the
    /// protocol would notice a dead peer.
    static let staleAfter: TimeInterval = 10

    static func isTrustworthy(lastUsed: Date, hasOpenStream: Bool, now: Date = .now) -> Bool {
        if hasOpenStream { return true }
        return now.timeIntervalSince(lastUsed) < staleAfter
    }
}

actor IrohService {
    private let monitor: IrohConnectionMonitor
    private var endpoint: Endpoint?

    /// One live serve connection **per paired server** (the resource-isolation
    /// rule: a node's connection is its own). Web views of different servers
    /// can stream simultaneously, so connections must not be swapped under
    /// each other; `openStream(nodeId:)` binds a tunnel to its own server.
    private var connections: [String: ServeConnection] = [:]
    /// The drop-watcher task per live connection.
    private var watchers: [String: Task<Void, Never>] = [:]
    /// The server the UI (detail/app host) is focused on: the default
    /// `httpRequest` target. Connection *state* is per node (`IrohConnectionMonitor`), so
    /// focus does not select it. Explicit `nodeId` parameters always win.
    private var activeNodeId: String?
    /// In-flight connect tasks per node, so a burst of callers (app host +
    /// revalidation) shares one dial instead of racing several.
    private var connecting: [String: Task<Connection, Error>] = [:]
    /// Consecutive connect failures per node, used to decide when the endpoint
    /// (and with it its cached peer addresses) is worth rebuilding.
    private var connectFailures: [String: Int] = [:]
    /// When the endpoint was last rebuilt, so a flaky network cannot make the
    /// client tear down and re-create its endpoint in a loop.
    private var lastEndpointRebuild: Date = .distantPast
    /// Failed dials in a row before the endpoint is rebuilt.
    private static let endpointRebuildFailureThreshold = 3
    /// Minimum time between endpoint rebuilds.
    private static let endpointRebuildCooldown: TimeInterval = 300
    /// Open stream count per node (a live tunnel keeps its connection fresh).
    private var openStreams: [String: Int] = [:]

    /// A live serve connection bound to the node it belongs to, stamped with
    /// the last time it carried traffic.
    private struct ServeConnection {
        let nodeId: String
        let conn: Connection
        var lastUsed: Date
    }

    private static let bindAlpn = Data("raemote/bind/0".utf8)
    private static let serveAlpn = Data("raemote/0".utf8)

    /// Generous budgets so a stuck peer can't hang the UI forever.
    private static let connectTimeout: Double = 15
    private static let requestTimeout: Double = 20
    /// The foreground liveness probe is a tiny request on a possibly-dead
    /// connection, so it uses a short deadline and recovers quickly.
    private static let validateTimeout: Double = 5

    init(monitor: IrohConnectionMonitor) {
        self.monitor = monitor
    }

    /// Record a connection-diagnosis event in the shared `ConnectionLog`
    /// (which also prints it to the console).
    ///
    /// Fire-and-forget onto the main actor so even *sync* actor methods can
    /// call it without introducing an await — and thus without widening a race
    /// window in code that is currently atomic. Ordering is best-effort.
    private nonisolated func log(_ message: String, nodeId: String? = nil) {
        Task { @MainActor in
            ConnectionLog.shared.append(message, nodeId: nodeId)
        }
    }

    // MARK: - Identity

    /// The `UserDefaults` key older builds used before the identity moved to
    /// the Keychain. Kept only to migrate it.
    private static let legacySecretKeyDefaultsKey = "irohSecretKey"

    private static func loadOrCreateSecretKey() async throws -> SecretKey {
        // 1. The Keychain is the source of truth.
        if let keyData = KeychainSecretStore.load(), keyData.count == 32 {
            return try SecretKey.fromBytes(bytes: keyData)
        }

        // 2. Migrate a key an older build left in UserDefaults. Only drop the
        //    legacy copy once it is safely in the Keychain.
        if let legacy = UserDefaults.standard.data(forKey: legacySecretKeyDefaultsKey),
           legacy.count == 32 {
            if KeychainSecretStore.save(legacy) {
                UserDefaults.standard.removeObject(forKey: legacySecretKeyDefaultsKey)
                print("[IrohService] migrated the device key from UserDefaults to the Keychain")
            } else {
                print("[IrohService] warning: could not migrate the device key to the Keychain")
            }
            return try SecretKey.fromBytes(bytes: legacy)
        }

        // 3. New identity: never create one without secure storage.
        let sk = SecretKey.generate()
        let bytes = sk.toBytes()
        guard KeychainSecretStore.save(bytes) else {
            throw IrohError.keyStoreFailed("the Keychain rejected the new key")
        }
        return sk
    }

    // MARK: - Endpoint

    private func ensureEndpoint() async throws -> Endpoint {
        if let ep = endpoint { return ep }

        let sk = try await Self.loadOrCreateSecretKey()
        let ep = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            secretKey: sk.toBytes(),
            alpns: []
        ))
        endpoint = ep
        log("endpoint bound (id: \(ep.id()))")
        return ep
    }

    // MARK: - Bind

    func bind(serverNodeId: String, token: String) async throws {
        await setFocus(serverNodeId)
        await setState(.connecting, for: serverNodeId)

        do {
            let ep = try await ensureEndpoint()
            log("pairing: my endpoint id: \(ep.id())", nodeId: serverNodeId)

            let remoteId = try EndpointId.fromString(s: serverNodeId)
            let remoteAddr = EndpointAddr(id: remoteId, relayUrl: nil, addresses: [])

            // 1. Auth: connect over bind ALPN, send token, read response, close.
            //    No timeout here: a slow first connection is common, and the UI
            //    offers a Cancel Pairing button after a while instead.
            log("pairing: connecting over bind ALPN…", nodeId: serverNodeId)
            let bindConn = try await withoutTimeout {
                try await ep.connect(addr: remoteAddr, alpn: Self.bindAlpn)
            }

            let bi = try await bindConn.openBi()
            try await bi.send().writeAll(buf: Data((token + "\n").utf8))
            try await bi.send().finish()

            let response = try await bi.recv().readToEnd(sizeLimit: 1024)
            let line = String(decoding: response, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            log("pairing: bind response: \(line)", nodeId: serverNodeId)

            guard line == "OK" else {
                let reason = line.hasPrefix("DENY ") ? String(line.dropFirst(5)) : line
                try bindConn.close(errorCode: 1, reason: Data("auth failed".utf8))
                throw IrohError.bindDenied(reason)
            }

            try bindConn.close(errorCode: 0, reason: Data("bind ok".utf8))

            // 2. Open a persistent connection over the serve ALPN.
            log("pairing: connecting over serve ALPN…", nodeId: serverNodeId)
            _ = try await connectAndAdopt(nodeId: serverNodeId, timeout: nil)
            await setState(.connected, for: serverNodeId)
            // Tell the server how this device should be named (best effort).
            try? await setDeviceName(DeviceNameStore.name, nodeId: serverNodeId)
            log("pairing: bound and ready", nodeId: serverNodeId)
        } catch is CancellationError {
            // The user aborted pairing; don't leave a misleading reason behind.
            log("pairing: cancelled", nodeId: serverNodeId)
            await setState(.disconnected(nil), for: serverNodeId)
            throw CancellationError()
        } catch {
            log("pairing failed: \(error.localizedDescription)", nodeId: serverNodeId)
            await setState(.disconnected(error.localizedDescription), for: serverNodeId)
            throw error
        }
    }

    /// Ensures a live serve connection to `nodeId`, reconnecting if needed.
    ///
    /// The server persists authorized nodes, so a client that previously bound
    /// can reconnect over `raemote/0` without the (short-lived) token.
    ///
    /// Running web apps keep their own connection per node; `focus` marks the
    /// node the UI is presenting (default HTTP target + path sampling).
    func ensureConnection(nodeId: String, focus: Bool = true) async throws {
        if focus { await setFocus(nodeId) }
        if reliableConnection(nodeId) != nil {
            if focus { await setState(.connected, for: nodeId) }
            return
        }
        _ = try await connectAndAdopt(nodeId: nodeId, timeout: Self.connectTimeout)
        if focus { await setState(.connected, for: nodeId) }
    }

    /// Marks which server the UI is presenting, so the parameterless
    /// `httpRequest` targets that server when no node id is passed.
    private func setFocus(_ nodeId: String) async {
        activeNodeId = nodeId
    }

    /// Actively verify the serve connection (used when the app returns to the
    /// foreground). Reconnects if the connection is gone, stale, or unusable.
    ///
    /// Every outcome is logged, and a failure now records *why* in the
    /// monitor — previously the connect/probe errors were swallowed and the
    /// indicator could sit on a stale state with no reason shown.
    func validateConnection(nodeId: String) async {
        await setFocus(nodeId)
        // Drop a connection whose close reason is known, or that has been idle
        // past the trust window (it may belong to a server process that has
        // since restarted). `ensureConnection` then dials fresh.
        if let cached = connections[nodeId],
           cached.conn.closeReason() != nil
            || !ConnectionFreshness.isTrustworthy(
                lastUsed: cached.lastUsed,
                hasOpenStream: (openStreams[nodeId] ?? 0) > 0
            ) {
            log("revalidate: dropping stale/closed connection", nodeId: nodeId)
            retire(nodeId, matching: cached.conn, reason: "stale")
        }
        do {
            try await ensureConnection(nodeId: nodeId)
        } catch {
            log("revalidate: connect failed: \(error.localizedDescription)", nodeId: nodeId)
            await setState(.disconnected(error.localizedDescription), for: nodeId)
            return
        }
        // Confirm it is actually usable. A short deadline means a dead
        // connection is detected in seconds, not the full request timeout.
        let probeStart = Date()
        do {
            _ = try await httpRequest(
                method: "GET",
                path: "/_hub/catalog",
                nodeId: nodeId,
                timeout: Self.validateTimeout
            )
            let ms = Int(Date().timeIntervalSince(probeStart) * 1000)
            log("revalidate: probe ok in \(ms)ms", nodeId: nodeId)
            await setState(.connected, for: nodeId)
        } catch {
            log("revalidate: probe failed: \(error.localizedDescription)", nodeId: nodeId)
            retire(nodeId, matching: connections[nodeId]?.conn, reason: "validation failed")
            await setState(.disconnected(error.localizedDescription), for: nodeId)
        }
    }

    /// The cached connection for `nodeId`, but only when it is alive and either
    /// recently used or carrying an open stream. A stale entry is retired here
    /// (and closed, so the server drops it immediately) and `nil` returned, so
    /// the caller dials a fresh connection.
    private func reliableConnection(_ nodeId: String) -> Connection? {
        guard let cached = connections[nodeId] else { return nil }
        guard cached.conn.closeReason() == nil else {
            retire(nodeId, matching: cached.conn, reason: "closed")
            return nil
        }
        let hasStream = (openStreams[nodeId] ?? 0) > 0
        guard ConnectionFreshness.isTrustworthy(lastUsed: cached.lastUsed, hasOpenStream: hasStream)
        else {
            let idle = Int(Date().timeIntervalSince(cached.lastUsed))
            log("dropping idle connection to \(nodeId.prefix(8)) (idle \(idle)s)", nodeId: nodeId)
            retire(nodeId, matching: cached.conn, reason: "stale")
            return nil
        }
        return cached.conn
    }

    /// Drop (and close) the cached connection for `nodeId`, but only when it is
    /// still `matching`, so a concurrent reconnect is never torn down. Closing
    /// tells iroh — and, when reachable, the server — to drop it now instead of
    /// waiting out the idle timeout.
    @discardableResult
    private func retire(_ nodeId: String, matching conn: Connection?, reason: String) -> Bool {
        guard let current = connections[nodeId],
              conn == nil || current.conn === conn
        else { return false }
        connections[nodeId] = nil
        watchers[nodeId]?.cancel()
        watchers[nodeId] = nil
        try? current.conn.close(errorCode: 0, reason: Data(reason.utf8))
        return true
    }

    /// Record that `conn` just carried traffic, so it stays "fresh".
    private func markUsed(_ nodeId: String, _ conn: Connection) {
        guard var cached = connections[nodeId], cached.conn === conn else { return }
        cached.lastUsed = .now
        connections[nodeId] = cached
    }

    /// Close and forget `nodeId`'s connection so the next request reconnects.
    /// Used when a tunnel proves the connection dead (or the user asks).
    func invalidateConnection(nodeId: String) async {
        retire(nodeId, matching: connections[nodeId]?.conn, reason: "invalidated")
    }

    /// Connect (or wait for an in-flight connect) over the serve ALPN and
    /// register the connection for `nodeId`.
    private func connectAndAdopt(nodeId: String, timeout: Double?) async throws -> Connection {
        if let existing = reliableConnection(nodeId) {
            return existing
        }
        retire(nodeId, matching: connections[nodeId]?.conn, reason: "reconnect")
        if let inflight = connecting[nodeId], !inflight.isCancelled {
            return try await inflight.value
        }
        let dialStart = Date()
        log(
            "dialing \(nodeId.prefix(8)) (timeout: \(timeout.map { "\(Int($0))s" } ?? "none"))",
            nodeId: nodeId
        )
        let task = Task {
            let ep = try await ensureEndpoint()
            let remoteId = try EndpointId.fromString(s: nodeId)
            let conn = try await Self.rawConnect(remoteId: remoteId, timeout: timeout, endpoint: ep)
            return try self.finishAdopt(conn, nodeId: nodeId)
        }
        connecting[nodeId] = task
        defer { connecting[nodeId] = nil }
        do {
            let conn = try await task.value
            connectFailures[nodeId] = nil
            let seconds = String(format: "%.1f", Date().timeIntervalSince(dialStart))
            log("connected to \(nodeId.prefix(8)) in \(seconds)s", nodeId: nodeId)
            return conn
        } catch {
            // A rejected (revoked) device is not a discovery problem; retrying
            // with a fresh endpoint would churn for nothing.
            if case IrohError.bindDenied = error {
                log("dial rejected: \(error.localizedDescription)", nodeId: nodeId)
                throw error
            }
            log("dial failed: \(error.localizedDescription)", nodeId: nodeId)
            await noteConnectFailure(nodeId)
            throw error
        }
    }

    /// A dial failed. After several in a row, rebuild the endpoint so address
    /// discovery runs from scratch — that is what recovers when the *cached*
    /// address of a restarted server has gone stale. Only done when no live
    /// connection exists (a working connection to another server proves
    /// discovery is fine and must not be torn down) and at most once every few
    /// minutes: on a flaky network, dials fail often, and rebuilding the
    /// endpoint tears down relay/discovery state, so churning it would make
    /// connectivity worse rather than better.
    private func noteConnectFailure(_ nodeId: String) async {
        let failures = (connectFailures[nodeId] ?? 0) + 1
        connectFailures[nodeId] = failures
        let hasLiveConnection = connections.values.contains { $0.conn.closeReason() == nil }
        let cooledDown = Date().timeIntervalSince(lastEndpointRebuild) >= Self.endpointRebuildCooldown
        guard failures >= Self.endpointRebuildFailureThreshold,
              !hasLiveConnection,
              cooledDown
        else { return }
        connectFailures[nodeId] = nil
        lastEndpointRebuild = .now
        guard let stale = endpoint else { return }
        log("\(failures) failed dials to \(nodeId.prefix(8)); rebuilding the endpoint to redo discovery", nodeId: nodeId)
        endpoint = nil
        try? await stale.close()
    }

    /// Connect over the serve ALPN. `timeout` of `nil` waits indefinitely (used
    /// during pairing, where the UI offers an explicit cancel instead).
    private nonisolated static func rawConnect(
        remoteId: EndpointId,
        timeout: Double?,
        endpoint: Endpoint
    ) async throws -> Connection {
        let remoteAddr = EndpointAddr(id: remoteId, relayUrl: nil, addresses: [])
        let conn: Connection
        if let timeout {
            conn = try await withTimeout(timeout) {
                try await endpoint.connect(addr: remoteAddr, alpn: serveAlpn)
            }
        } else {
            conn = try await withoutTimeout {
                try await endpoint.connect(addr: remoteAddr, alpn: serveAlpn)
            }
        }
        // Give the server's 401-rejection a beat to arrive before declaring
        // the connection established.
        try? await Task.sleep(for: .milliseconds(300))
        return conn
    }

    /// Register freshly created connection: per-node watcher keyed to it.
    private func finishAdopt(_ conn: Connection, nodeId: String) throws -> Connection {
        // The server closes unauthorized connections immediately (code 401).
        if let reason = conn.closeReason() {
            throw IrohError.bindDenied(
                "server rejected the connection (node not authorized) — set up the server link again [\(reason)]"
            )
        }
        connections[nodeId] = ServeConnection(nodeId: nodeId, conn: conn, lastUsed: .now)
        watchers[nodeId]?.cancel()
        // The watcher is bound to THIS connection, not the node key: if the
        // connection drops after a reconnect already adopted a newer one, the
        // stale watcher must not evict the live connection (identity compares
        // inside `connectionDropped`).
        watchers[nodeId] = Task { [weak self] in
            let reason = await conn.closed()
            await self?.connectionDropped(conn, nodeId: nodeId, reason: reason)
        }
        return conn
    }

    private func connectionDropped(_ conn: Connection, nodeId: String, reason: String) async {
        // Identity fence: only retire the map entry this watcher was created
        // for. A dropped OLD connection after a reconnect must not tear down
        // the live one.
        guard connections[nodeId]?.conn === conn else { return }
        connections[nodeId] = nil
        watchers[nodeId]?.cancel()
        watchers[nodeId] = nil
        log("serve connection dropped: \(reason)", nodeId: nodeId)
        // Recorded for *this* node only, so a drop on one server never shows up
        // as another server's state.
        await setState(.disconnected(reason), for: nodeId)
    }

    private func setState(_ state: IrohConnectionState, for nodeId: String) async {
        let monitor = self.monitor
        await MainActor.run {
            monitor.setState(state, for: nodeId)
        }
    }

    // MARK: - HTTP over iroh

    /// `nodeId` overrides the focused server; nil uses `activeNodeId`. Always
    /// pass an explicit node when the request belongs to a specific server (a
    /// background session must never ride the focused server's connection).
    func httpRequest(
        method: String,
        path: String,
        nodeId: String? = nil,
        body: Data? = nil,
        contentType: String = "application/json",
        timeout: Double? = nil
    ) async throws -> (Int, Data) {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: raemote\r\n"
        if let body, !body.isEmpty {
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var request = Data(head.utf8)
        if let body { request.append(body) }

        log("\(method) \(path) — opening bi-stream", nodeId: nodeId ?? activeNodeId)
        let raw = try await send(
            request,
            sizeLimit: 1_000_000,
            timeout: timeout ?? Self.requestTimeout,
            nodeId: nodeId
        )
        return try Self.parseHttpResponse(raw)
    }

    /// Send one request, self-healing once if the connection is dead.
    private func send(
        _ requestData: Data,
        sizeLimit: UInt32,
        timeout: Double,
        nodeId explicitNodeId: String?
    ) async throws -> Data {
        guard let nodeId = explicitNodeId ?? activeNodeId else {
            throw IrohError.connectionFailed("Not bound")
        }
        // Reuse only a connection that is alive and not suspiciously idle; a
        // fresh dial is cheap, a hang on a connection whose server has
        // restarted is not.
        if let conn = reliableConnection(nodeId) {
            do {
                let data = try await withTimeout(timeout) {
                    try await Self.exchange(conn, requestData: requestData, sizeLimit: sizeLimit)
                }
                markUsed(nodeId, conn)
                return data
            } catch {
                log("request failed, will reconnect: \(error)", nodeId: nodeId)
                // Only retire the entry that actually failed: a concurrent
                // reconnect may have adopted a different connection under the
                // same key while this exchange was in flight.
                retire(nodeId, matching: conn, reason: "request failed")
            }
        }

        _ = try await connectAndAdopt(nodeId: nodeId, timeout: Self.connectTimeout)
        guard let conn = connections[nodeId]?.conn else {
            throw IrohError.connectionFailed("connection lost")
        }
        do {
            let data = try await withTimeout(timeout) {
                try await Self.exchange(conn, requestData: requestData, sizeLimit: sizeLimit)
            }
            markUsed(nodeId, conn)
            return data
        } catch {
            await setState(.disconnected(error.localizedDescription), for: nodeId)
            throw error
        }
    }

    /// An open bidirectional serve stream, used by the streaming proxy tunnel.
    struct RawStream: Sendable {
        let send: SendStream
        let recv: RecvStream
    }

    /// Open a bidirectional stream on `nodeId`'s serve connection (for the
    /// streaming proxy). Unlike `relay`, the caller owns both halves and pumps
    /// bytes. The node is explicit so a tunnel can never ride another server's
    /// connection.
    ///
    /// While this stream is open the connection counts as fresh, so a
    /// long-lived tunnel is never dropped by the idle window; call
    /// `streamFinished(nodeId:)` when the tunnel ends.
    func openStream(nodeId: String) async throws -> RawStream {
        let conn = try await connectAndAdopt(nodeId: nodeId, timeout: Self.connectTimeout)
        let stream = try await withTimeout(Self.requestTimeout) {
            let bi = try await conn.openBi()
            return RawStream(send: bi.send(), recv: bi.recv())
        }
        openStreams[nodeId, default: 0] += 1
        markUsed(nodeId, conn)
        return stream
    }

    /// The tunnel using `nodeId`'s stream has ended.
    func streamFinished(nodeId: String) {
        if let count = openStreams[nodeId], count > 1 {
            openStreams[nodeId] = count - 1
        } else {
            openStreams[nodeId] = nil
        }
        if let conn = connections[nodeId]?.conn {
            markUsed(nodeId, conn)
        }
    }

    private nonisolated static func exchange(
        _ conn: Connection,
        requestData: Data,
        sizeLimit: UInt32
    ) async throws -> Data {
        let bi = try await conn.openBi()
        let send = bi.send()
        try await send.writeAll(buf: requestData)
        try await send.finish()
        return try await bi.recv().readToEnd(sizeLimit: sizeLimit)
    }

    // MARK: - Catalog

    struct CatalogResponse: Codable {
        let apps: [AppInfo]
    }

    func fetchCatalog(nodeId: String? = nil) async throws -> [AppInfo] {
        let (status, body) = try await httpRequest(method: "GET", path: "/_hub/catalog", nodeId: nodeId)
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try Self.decodeCatalog(body)
    }

    /// Ask the server to rescan for local apps, then return the fresh catalog.
    func discoverCatalog(nodeId: String? = nil) async throws -> [AppInfo] {
        let (status, body) = try await httpRequest(method: "POST", path: "/_hub/discover", nodeId: nodeId)
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try Self.decodeCatalog(body)
    }

    private static func decodeCatalog(_ body: Data) throws -> [AppInfo] {
        // Server returns {"apps": [...]} — unwrap first.
        if let wrapper = try? JSONDecoder().decode(CatalogResponse.self, from: body) {
            return wrapper.apps
        }
        // Fallback: plain array.
        return try JSONDecoder().decode([AppInfo].self, from: body)
    }

    // MARK: - Server info

    struct ServerInfo: Codable {
        let name: String
        let version: String?
    }

    /// Fetch the server's display name and version.
    func fetchServerInfo(nodeId: String? = nil) async throws -> ServerInfo {
        let (status, body) = try await httpRequest(method: "GET", path: "/_hub/info", nodeId: nodeId)
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try JSONDecoder().decode(ServerInfo.self, from: body)
    }

    /// Fetch an app's icon through its `/app/{name}` route. `path` is the
    /// same-origin icon path the server's discovery reported; when it is
    /// absent (a manual app, or an older server) the conventional
    /// `/favicon.ico` is tried instead.
    func fetchIcon(nodeId: String, app: String, path: String?) async throws -> Data {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let iconPath = trimmed.hasPrefix("/") ? trimmed : "/favicon.ico"
        let (status, body) = try await httpRequest(
            method: "GET",
            path: "/app/\(app)\(iconPath)",
            nodeId: nodeId
        )
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return body
    }

    // MARK: - Invitations

    /// A one-time invitation returned by `POST /_hub/invite`.
    struct Invitation: Decodable {
        /// The `raemote://bind?...` link another device scans to pair.
        let uri: String
        /// Unix expiry of the invitation.
        let expiresAtUnix: UInt64

        private enum CodingKeys: String, CodingKey {
            case uri
            case expiresAtUnix = "expires_at_unix"
        }
    }

    /// Mint a one-time invitation so another device can pair with this server.
    func createInvitation(nodeId: String? = nil) async throws -> Invitation {
        let (status, body) = try await httpRequest(method: "POST", path: "/_hub/invite", nodeId: nodeId)
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try JSONDecoder().decode(Invitation.self, from: body)
    }

    // MARK: - Device name

    /// Ask the server to store this device's display name.
    func setDeviceName(_ name: String, nodeId: String? = nil) async throws {
        struct Body: Encodable { let name: String }
        let body = try JSONEncoder().encode(Body(name: name))
        let (status, responseBody) = try await httpRequest(
            method: "PUT",
            path: "/_hub/device",
            nodeId: nodeId,
            body: body
        )
        guard status == 200 else {
            throw IrohError.http(status: status, body: responseBody)
        }
    }

    /// Best-effort: set this device's name on each bound server. Background,
    /// non-focused: it must not steal the UI's focused connection state.
    func syncDeviceName(to nodeIds: [String], name: String) async {
        for nodeId in nodeIds {
            do {
                try await ensureConnection(nodeId: nodeId, focus: false)
                try await setDeviceName(name, nodeId: nodeId)
            } catch {
                log("could not set device name: \(error)", nodeId: nodeId)
            }
        }
    }

    // MARK: - HTTP response parser

    private static func parseHttpResponse(_ data: Data) throws -> (Int, Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw IrohError.decodeFailed("Missing header terminator")
        }

        let headerData = data[..<headerEnd.lowerBound]
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""

        let statusLine = headerStr.components(separatedBy: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw IrohError.decodeFailed("Bad status line: \(statusLine)")
        }

        let body = Data(data[headerEnd.upperBound...])
        return (code, body)
    }

    // MARK: - Cleanup

    func disconnect() async {
        for watcher in watchers.values {
            watcher.cancel()
        }
        for cached in connections.values {
            try? cached.conn.close(errorCode: 0, reason: Data("bye".utf8))
        }
        connections.removeAll()
        watchers.removeAll()
        connecting.removeAll()
        openStreams.removeAll()
        activeNodeId = nil
        endpoint = nil
        log("endpoint torn down")
        let monitor = monitor
        await MainActor.run { monitor.reset() }
    }
}

// MARK: - Timeout helper

/// Resumes a continuation at most once, so a timeout and a late-returning
/// operation can't both resume it. NSLock-guarded; callable from any executor
/// (the timeout task races the operation task), hence `nonisolated`.
private nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false

    nonisolated func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    nonisolated func resume(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Races `operation` against a timeout and against task cancellation. The
/// underlying iroh future isn't cancellable, so an abandoned operation is left
/// to finish (and its result discarded) rather than awaited.
private func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = ResumeOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
            Task {
                do {
                    box.resume(.success(try await operation()))
                } catch {
                    box.resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                box.resume(.failure(IrohError.connectionFailed("timed out after \(Int(seconds))s — make sure your computer is awake and online")))
            }
        }
    } onCancel: {
        box.resume(.failure(CancellationError()))
    }
}

/// Awaits `operation` with no timeout, but aborts early if the surrounding task
/// is cancelled. Used while pairing, where the UI offers an explicit cancel.
private func withoutTimeout<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = ResumeOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
            Task {
                do {
                    box.resume(.success(try await operation()))
                } catch {
                    box.resume(.failure(error))
                }
            }
        }
    } onCancel: {
        box.resume(.failure(CancellationError()))
    }
}
