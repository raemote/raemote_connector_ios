import Foundation
import Network

/// A tiny loopback HTTP/1.1 proxy.
///
/// WKWebView is pointed at `http://127.0.0.1:<port>/`; every connection it makes
/// is handled by a `ProxyTunnel`, which rewrites the path to `/app/<name><path>`
/// and streams bytes both ways over iroh.
///
/// This is what makes web apps reachable on a physical device: `127.0.0.1`
/// inside WKWebView means this proxy, not the developer's machine.
nonisolated final class LocalProxyServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.raemote.LocalProxyServer")
    private let appName: String
    /// The server whose `/app/{name}` route this proxy relays to. Streams are
    /// opened on that server's connection; tunnels must never ride another
    /// server's connection.
    private let nodeId: String
    private let service: IrohService
    private let preferredPort: UInt16?
    private var listener: NWListener?
    /// Accepted connections still being relayed, tracked so `stop()` can end
    /// every tunnel deterministically (an abandoned pump would keep its NWConnection
    /// and its iroh stream alive with no owner after the session is closed).
    /// All access is on `queue`.
    private var tunnels: [ObjectIdentifier: NWConnection] = [:]

    init(nodeId: String, appName: String, service: IrohService, preferredPort: UInt16? = nil) {
        self.nodeId = nodeId
        self.appName = appName
        self.service = service
        self.preferredPort = preferredPort
    }

    /// Starts listening and resolves once the port is known.
    ///
    /// Tries `preferredPort` first so the page keeps a **stable origin** across
    /// launches — site data (cookies, localStorage, IndexedDB, service workers)
    /// is scoped to the origin *including the port*. Falls back to an ephemeral
    /// port if the preferred one is unavailable.
    func start() async throws -> UInt16 {
        if let preferredPort {
            if let port = try? await listen(on: preferredPort) {
                return port
            }
        }
        return try await listen(on: nil)
    }

    private func listen(on port: UInt16?) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // The state handler is a Sendable closure that Network.framework may
            // invoke off the main actor, so resume through a lock-protected gate
            // instead of a captured `var`.
            let gate = ContinuationGate<UInt16>()
            gate.store(continuation)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    gate.resume(.failure(error))
                case .cancelled:
                    gate.resume(.failure(IrohError.connectionFailed("proxy cancelled")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        // Queue-serialized fence: end the listener AND every live tunnel, so
        // no pump outlives its owner. Pumps observe the cancellation as a
        // receive/send error and exit.
        queue.async(execute: teardownListenerAndTunnels)
    }

    /// Runs on `queue`.
    private func teardownListenerAndTunnels() {
        listener?.cancel()
        listener = nil
        for connection in tunnels.values {
            connection.cancel()
        }
        tunnels.removeAll()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        // Track the tunnel so stop() can end it deterministically.
        queue.async(execute: { self.track(connection) })
        connection.start(queue: queue)
        let tunnel = ProxyTunnel(connection: connection, appName: appName, service: service, nodeId: nodeId)
        Task.detached { [weak self] in
            await tunnel.start()
            // The pump finished (stream end, error, or listener teardown):
            // drop the tracked entry.
            self?.untrack(connection)
        }
    }

    /// Runs on `queue`.
    private func track(_ connection: NWConnection) {
        tunnels[ObjectIdentifier(connection)] = connection
    }

    /// Runs on `queue`.
    private func untrack(_ connection: NWConnection) {
        tunnels.removeValue(forKey: ObjectIdentifier(connection))
    }
}

/// Resumes a continuation at most once from any thread.
nonisolated private final class ContinuationGate<T>: @unchecked Sendable {
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
