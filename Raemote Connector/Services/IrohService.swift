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

/// How the live serve connection currently reaches the server.
nonisolated enum IrohPathKind: Equatable, Sendable {
    /// No selected path yet — still connecting, or the connection is down.
    case unknown
    /// A direct peer-to-peer path (the NAT-traversed IP path).
    case direct
    /// Application data is being forwarded through a relay.
    case relayed

    /// Classify a set of open paths.
    ///
    /// The **selected** path is what carries application data, so it decides.
    /// That matters: iroh usually holds a relay path open as a fallback and may
    /// start on it before hole-punching upgrades the connection to a direct
    /// path, so this flips from `.relayed` to `.direct` on its own.
    init(paths: [IrohPathFacts]) {
        if let selected = paths.first(where: \.isSelected) {
            self = selected.isRelay ? .relayed : (selected.isIp ? .direct : .unknown)
        } else if paths.contains(where: { $0.isIp && !$0.isRelay }) {
            self = .direct
        } else if paths.contains(where: \.isRelay) {
            self = .relayed
        } else {
            self = .unknown
        }
    }
}

/// The parts of an iroh `PathSnapshot` that decide direct vs relayed.
///
/// Kept as plain data so the decision above is unit-testable: the FFI record
/// can't be constructed from the test target.
nonisolated struct IrohPathFacts: Equatable, Sendable {
    var isSelected: Bool
    var isIp: Bool
    var isRelay: Bool

    init(isSelected: Bool, isIp: Bool, isRelay: Bool) {
        self.isSelected = isSelected
        self.isIp = isIp
        self.isRelay = isRelay
    }

    init(_ snapshot: PathSnapshot) {
        self.init(
            isSelected: snapshot.isSelected,
            isIp: snapshot.isIp,
            isRelay: snapshot.isRelay
        )
    }
}

/// The live connection's path state, bound to the server it describes, so a
/// stale or in-flight update can never be shown for a different server.
nonisolated struct IrohPathState: Equatable, Sendable {
    var nodeId: String
    var kind: IrohPathKind

    /// The kind for `nodeId`, or `nil` when the recorded path belongs to
    /// another server.
    func kind(for nodeId: String) -> IrohPathKind? {
        self.nodeId == nodeId ? kind : nil
    }
}

/// Observable mirror of the iroh serve connection, updated by `IrohService`.
///
/// `IrohService` is an actor and can't be observed directly by SwiftUI, so it
/// pushes state changes into this main-actor model.
@MainActor
@Observable
final class IrohConnectionMonitor {
    var state: IrohConnectionState = .unknown
    /// How the live serve connection reaches the server, when known.
    var path: IrohPathState?
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
    /// The server the UI (detail/web view) is focused on: the monitor's state
    /// and the default `httpRequest` target. Explicit `nodeId` parameters
    /// always win over this.
    private var activeNodeId: String?
    /// In-flight connect tasks per node, so a burst of callers (web view +
    /// revalidation) shares one dial instead of racing several.
    private var connecting: [String: Task<Connection, Error>] = [:]
    /// Consecutive connect failures per node, used to decide when the endpoint
    /// (and with it its cached peer addresses) is worth rebuilding.
    private var connectFailures: [String: Int] = [:]
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
        return ep
    }

    // MARK: - Bind

    func bind(serverNodeId: String, token: String) async throws {
        await setFocus(serverNodeId)
        await setState(.connecting)

        do {
            let ep = try await ensureEndpoint()
            print("[IrohService] my endpoint id: \(ep.id())")

            let remoteId = try EndpointId.fromString(s: serverNodeId)
            let remoteAddr = EndpointAddr(id: remoteId, relayUrl: nil, addresses: [])

            // 1. Auth: connect over bind ALPN, send token, read response, close.
            //    No timeout here: a slow first connection is common, and the UI
            //    offers a Cancel Pairing button after a while instead.
            print("[IrohService] connecting over bind ALPN...")
            let bindConn = try await withoutTimeout {
                try await ep.connect(addr: remoteAddr, alpn: Self.bindAlpn)
            }

            let bi = try await bindConn.openBi()
            try await bi.send().writeAll(buf: Data((token + "\n").utf8))
            try await bi.send().finish()

            let response = try await bi.recv().readToEnd(sizeLimit: 1024)
            let line = String(decoding: response, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("[IrohService] bind response: \(line)")

            guard line == "OK" else {
                let reason = line.hasPrefix("DENY ") ? String(line.dropFirst(5)) : line
                try bindConn.close(errorCode: 1, reason: Data("auth failed".utf8))
                throw IrohError.bindDenied(reason)
            }

            try bindConn.close(errorCode: 0, reason: Data("bind ok".utf8))

            // 2. Open a persistent connection over the serve ALPN.
            print("[IrohService] connecting over serve ALPN...")
            _ = try await connectAndAdopt(nodeId: serverNodeId, timeout: nil)
            await setState(.connected)
            // Tell the server how this device should be named (best effort).
            try? await setDeviceName(DeviceNameStore.name, nodeId: serverNodeId)
            print("[IrohService] bound and ready")
        } catch is CancellationError {
            // The user aborted pairing; don't leave a misleading reason behind.
            await setState(.disconnected(nil))
            throw CancellationError()
        } catch {
            await setState(.disconnected(error.localizedDescription))
            throw error
        }
    }

    /// Ensures a live serve connection to `nodeId`, reconnecting if needed.
    ///
    /// The server persists authorized nodes, so a client that previously bound
    /// can reconnect over `raemote/0` without the (short-lived) token.
    ///
    /// Running web apps keep their own connection per node; `focus` marks the
    /// node the UI is presenting (monitor state + default HTTP target).
    func ensureConnection(nodeId: String, focus: Bool = true) async throws {
        if focus { await setFocus(nodeId) }
        if reliableConnection(nodeId) != nil {
            if focus { await setState(.connected) }
            return
        }
        _ = try await connectAndAdopt(nodeId: nodeId, timeout: Self.connectTimeout)
        if focus { await setState(.connected) }
    }

    /// Marks which server the UI is presenting, so monitor state and the
    /// parameterless `httpRequest` describe that server.
    private func setFocus(_ nodeId: String) async {
        if activeNodeId != nodeId {
            activeNodeId = nodeId
            // Any sampled path describes the *previous* focus; drop it so the
            // UI never shows another server's transport info. The path-binding
            // check (`IrohPathState.kind(for:)`) is the second guard.
            let monitor = monitor
            await MainActor.run { monitor.path = nil }
        }
    }

    /// Actively verify the serve connection (used when the app returns to the
    /// foreground). Reconnects if the connection is gone, stale, or unusable.
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
            retire(nodeId, matching: cached.conn, reason: "stale")
        }
        do {
            try await ensureConnection(nodeId: nodeId)
        } catch {
            return
        }
        // Confirm it is actually usable. A short deadline means a dead
        // connection is detected in seconds, not the full request timeout.
        do {
            _ = try await httpRequest(
                method: "GET",
                path: "/_hub/catalog",
                nodeId: nodeId,
                timeout: Self.validateTimeout
            )
            await setState(.connected)
        } catch {
            retire(nodeId, matching: connections[nodeId]?.conn, reason: "validation failed")
            await setState(.disconnected("connection unusable"))
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
            print("[IrohService] dropping idle connection to \(nodeId.prefix(8)) (idle \(idle)s)")
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
            return conn
        } catch {
            // A rejected (revoked) device is not a discovery problem; retrying
            // with a fresh endpoint would churn for nothing.
            if case IrohError.bindDenied = error {
                throw error
            }
            await noteConnectFailure(nodeId)
            throw error
        }
    }

    /// A dial failed. After a couple in a row, rebuild the endpoint so address
    /// discovery runs from scratch — that is what recovers when the *cached*
    /// address of a restarted server has gone stale. Only done when no live
    /// connection exists: a working connection to another server proves
    /// discovery is fine and must not be torn down.
    private func noteConnectFailure(_ nodeId: String) async {
        let failures = (connectFailures[nodeId] ?? 0) + 1
        connectFailures[nodeId] = failures
        let hasLiveConnection = connections.values.contains { $0.conn.closeReason() == nil }
        guard failures >= 2, !hasLiveConnection else { return }
        connectFailures[nodeId] = nil
        guard let stale = endpoint else { return }
        print("[IrohService] \(failures) failed dials to \(nodeId.prefix(8)); rebuilding the endpoint to redo discovery")
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

    /// Sample how the live connection reaches the server and publish it.
    ///
    /// This is deliberately a pull, not `Connection.watchPaths`: the sync
    /// `watch_*` FFI methods in the pinned `iroh-ffi` prebuilt (v1.1.0) call
    /// `tokio::spawn` on the *caller's* thread, which has no tokio runtime, and
    /// abort the process with "there is no reactor running". Upstream fixed it
    /// after v1.1.0 (iroh-ffi #281), but the app links the v1.1.0 prebuilt, so
    /// `paths()` (a plain snapshot, no spawn) is the safe surface. A couple of
    /// seconds of lag is fine for a transport indicator.
    func refreshPathKind(nodeId: String) async {
        // Only sample an alive connection; an idle one is left alone here (the
        // staleness window is applied when it is next *used*, never by polling,
        // so a running-but-quiet tunnel is not torn down).
        guard let cached = connections[nodeId], cached.conn.closeReason() == nil else {
            return
        }
        let kind = IrohPathKind(paths: cached.conn.paths().map(IrohPathFacts.init))
        await MainActor.run { monitor.path = IrohPathState(nodeId: nodeId, kind: kind) }
    }

    private func connectionDropped(_ conn: Connection, nodeId: String, reason: String) async {
        // Identity fence: only retire the map entry this watcher was created
        // for. A dropped OLD connection after a reconnect must not tear down
        // the live one.
        guard connections[nodeId]?.conn === conn else { return }
        connections[nodeId] = nil
        watchers[nodeId]?.cancel()
        watchers[nodeId] = nil
        print("[IrohService] serve connection dropped: \(nodeId.prefix(8)) \(reason)")
        if activeNodeId == nodeId {
            await setState(.disconnected(reason))
        }
    }

    private func setState(_ state: IrohConnectionState) async {
        let monitor = self.monitor
        await MainActor.run {
            monitor.state = state
            // A path only describes a live connection; drop it otherwise so the
            // UI never shows a stale "direct"/"relayed" for a dead connection.
            if state != .connected { monitor.path = nil }
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

        print("[IrohService] \(method) \(path) — opening bi-stream")
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
                print("[IrohService] request failed, will reconnect: \(error)")
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
            if nodeId == activeNodeId {
                await setState(.disconnected(error.localizedDescription))
            }
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
                print("[IrohService] could not set device name on \(nodeId.prefix(8)): \(error)")
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
        await setState(.unknown)
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
