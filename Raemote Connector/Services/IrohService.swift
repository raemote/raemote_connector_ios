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

actor IrohService {
    private let monitor: IrohConnectionMonitor
    private var endpoint: Endpoint?
    private var httpConnection: Connection?
    private var remoteNodeId: String?
    /// The node the live `httpConnection` is actually connected to. Kept in sync
    /// with `remoteNodeId` so a request for server B never rides A's connection.
    private var connectedNodeId: String?
    private var connectionWatcher: Task<Void, Never>?

    private static let bindAlpn = Data("raemote/bind/0".utf8)
    private static let serveAlpn = Data("raemote/0".utf8)

    /// Generous budgets so a stuck peer can't hang the UI forever.
    private static let connectTimeout: Double = 15
    private static let requestTimeout: Double = 20

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
        dropConnectionIfDifferentNode(serverNodeId)
        remoteNodeId = serverNodeId
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
            let conn = try await connect(remoteId: remoteId, timeout: nil)
            adopt(conn, nodeId: serverNodeId)
            await setState(.connected)
            // Tell the server how this device should be named (best effort).
            try? await setDeviceName(DeviceNameStore.name)
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

    /// Ensures a live serve connection exists, reconnecting if needed.
    ///
    /// The server persists authorized nodes, so a client that previously bound
    /// can reconnect over `raemote/0` without the (short-lived) token.
    func ensureConnection(nodeId: String) async throws {
        dropConnectionIfDifferentNode(nodeId)
        remoteNodeId = nodeId
        if let conn = httpConnection, conn.closeReason() == nil {
            await setState(.connected)
            return
        }
        await setState(.connecting)
        do {
            let remoteId = try EndpointId.fromString(s: nodeId)
            let conn = try await connect(remoteId: remoteId, timeout: Self.connectTimeout)
            adopt(conn, nodeId: nodeId)
            await setState(.connected)
        } catch {
            await setState(.disconnected(error.localizedDescription))
            throw error
        }
    }

    /// Close the live connection when it belongs to a different server, so a
    /// request for server B can't reuse server A's connection.
    private func dropConnectionIfDifferentNode(_ nodeId: String) {
        guard let conn = httpConnection,
              !Self.canReuseConnection(connected: connectedNodeId, requested: nodeId)
        else { return }
        print("[IrohService] switching server: closing connection to \(connectedNodeId?.prefix(8) ?? "?")")
        connectionWatcher?.cancel()
        connectionWatcher = nil
        try? conn.close(errorCode: 0, reason: Data("switching server".utf8))
        httpConnection = nil
        connectedNodeId = nil
    }

    /// Whether a live serve connection to `connected` may serve a request for
    /// `requested`. Never reuse across different servers.
    nonisolated static func canReuseConnection(connected: String?, requested: String?) -> Bool {
        guard let connected, let requested else { return false }
        return connected == requested
    }

    /// Actively verify the serve connection (used when the app returns to the
    /// foreground). Reconnects if the connection is gone or unusable.
    func validateConnection(nodeId: String) async {
        remoteNodeId = nodeId
        // Drop a connection whose close reason is already known.
        if let conn = httpConnection, conn.closeReason() != nil {
            httpConnection = nil
            connectedNodeId = nil
        }
        do {
            try await ensureConnection(nodeId: nodeId)
        } catch {
            return
        }
        // Confirm it is actually usable; `send` self-heals if it is half-dead.
        do {
            _ = try await httpRequest(method: "GET", path: "/_hub/catalog")
            await setState(.connected)
        } catch {
            await setState(.disconnected("connection unusable"))
        }
    }

    /// Connect over the serve ALPN. `timeout` of `nil` waits indefinitely (used
    /// during pairing, where the UI offers an explicit cancel instead).
    private func connect(remoteId: EndpointId, timeout: Double?) async throws -> Connection {
        let ep = try await ensureEndpoint()
        let remoteAddr = EndpointAddr(id: remoteId, relayUrl: nil, addresses: [])
        let conn: Connection
        if let timeout {
            conn = try await withTimeout(timeout) {
                try await ep.connect(addr: remoteAddr, alpn: Self.serveAlpn)
            }
        } else {
            conn = try await withoutTimeout {
                try await ep.connect(addr: remoteAddr, alpn: Self.serveAlpn)
            }
        }

        // The server closes unauthorized connections immediately (code 401).
        try? await Task.sleep(for: .milliseconds(300))
        if let reason = conn.closeReason() {
            throw IrohError.bindDenied(
                "server rejected the connection (node not authorized) — set up the server link again [\(reason)]"
            )
        }
        return conn
    }

    /// Store `conn` as the active connection and watch for it dropping.
    ///
    /// `nodeId` is the server this connection was made to (rather than the
    /// current `remoteNodeId`, which a concurrent call may have changed).
    private func adopt(_ conn: Connection, nodeId: String) {
        httpConnection = conn
        connectedNodeId = nodeId
        remoteNodeId = nodeId
        connectionWatcher?.cancel()
        connectionWatcher = Task { [weak self] in
            let reason = await conn.closed()
            await self?.connectionDropped(conn, reason: reason)
        }
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
        guard let conn = httpConnection, connectedNodeId == nodeId, conn.closeReason() == nil else {
            return
        }
        let kind = IrohPathKind(paths: conn.paths().map(IrohPathFacts.init))
        await MainActor.run { monitor.path = IrohPathState(nodeId: nodeId, kind: kind) }
    }

    private func connectionDropped(_ conn: Connection, reason: String) async {
        guard httpConnection === conn else { return }
        httpConnection = nil
        connectedNodeId = nil
        print("[IrohService] serve connection dropped: \(reason)")
        await setState(.disconnected(reason))
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

    func httpRequest(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String = "application/json"
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
            timeout: Self.requestTimeout
        )
        return try Self.parseHttpResponse(raw)
    }

    /// Send one request, self-healing once if the current connection is dead.
    private func send(_ requestData: Data, sizeLimit: UInt32, timeout: Double) async throws -> Data {
        // Never reuse a connection to a different server.
        if let nodeId = remoteNodeId {
            dropConnectionIfDifferentNode(nodeId)
        }
        if let conn = httpConnection, conn.closeReason() == nil {
            do {
                return try await withTimeout(timeout) {
                    try await Self.exchange(conn, requestData: requestData, sizeLimit: sizeLimit)
                }
            } catch {
                print("[IrohService] request failed, will reconnect: \(error)")
                httpConnection = nil
                connectedNodeId = nil
            }
        }

        let conn = try await ensureServeConnection()
        do {
            return try await withTimeout(timeout) {
                try await Self.exchange(conn, requestData: requestData, sizeLimit: sizeLimit)
            }
        } catch {
            await setState(.disconnected(error.localizedDescription))
            throw error
        }
    }

    /// The live serve connection, connecting (or reconnecting) if needed.
    private func ensureServeConnection() async throws -> Connection {
        if let nodeId = remoteNodeId {
            dropConnectionIfDifferentNode(nodeId)
        }
        if let conn = httpConnection, conn.closeReason() == nil {
            return conn
        }
        guard let nodeId = remoteNodeId else {
            throw IrohError.connectionFailed("Not bound")
        }
        await setState(.connecting)
        let remoteId = try EndpointId.fromString(s: nodeId)
        let conn: Connection
        do {
            conn = try await connect(remoteId: remoteId, timeout: Self.connectTimeout)
        } catch {
            await setState(.disconnected(error.localizedDescription))
            throw error
        }
        adopt(conn, nodeId: nodeId)
        await setState(.connected)
        return conn
    }

    /// An open bidirectional serve stream, used by the streaming proxy tunnel.
    struct RawStream: Sendable {
        let send: SendStream
        let recv: RecvStream
    }

    /// Open a bidirectional stream on the serve connection (for the streaming
    /// proxy). Unlike `relay`, the caller owns both halves and pumps bytes.
    func openStream() async throws -> RawStream {
        let conn = try await ensureServeConnection()
        let bi = try await conn.openBi()
        return RawStream(send: bi.send(), recv: bi.recv())
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

    func fetchCatalog() async throws -> [AppInfo] {
        let (status, body) = try await httpRequest(method: "GET", path: "/_hub/catalog")
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try Self.decodeCatalog(body)
    }

    /// Ask the server to rescan for local apps, then return the fresh catalog.
    func discoverCatalog() async throws -> [AppInfo] {
        let (status, body) = try await httpRequest(method: "POST", path: "/_hub/discover")
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
    func fetchServerInfo() async throws -> ServerInfo {
        let (status, body) = try await httpRequest(method: "GET", path: "/_hub/info")
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try JSONDecoder().decode(ServerInfo.self, from: body)
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
    func createInvitation() async throws -> Invitation {
        let (status, body) = try await httpRequest(method: "POST", path: "/_hub/invite")
        guard status == 200 else {
            throw IrohError.http(status: status, body: body)
        }
        return try JSONDecoder().decode(Invitation.self, from: body)
    }

    // MARK: - Device name

    /// Ask the connected server to store this device's display name.
    func setDeviceName(_ name: String) async throws {
        struct Body: Encodable { let name: String }
        let body = try JSONEncoder().encode(Body(name: name))
        let (status, responseBody) = try await httpRequest(
            method: "PUT",
            path: "/_hub/device",
            body: body
        )
        guard status == 200 else {
            throw IrohError.http(status: status, body: responseBody)
        }
    }

    /// Best-effort: set this device's name on each bound server.
    func syncDeviceName(to nodeIds: [String], name: String) async {
        for nodeId in nodeIds {
            do {
                try await ensureConnection(nodeId: nodeId)
                try await setDeviceName(name)
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
        connectionWatcher?.cancel()
        connectionWatcher = nil
        if let conn = httpConnection {
            try? conn.close(errorCode: 0, reason: Data("bye".utf8))
            httpConnection = nil
        }
        connectedNodeId = nil
        endpoint = nil
        await setState(.unknown)
    }
}

// MARK: - Timeout helper

/// Resumes a continuation at most once, so a timeout and a late-returning
/// operation can't both resume it.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false

    func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
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
