import Foundation
import IrohLib
import Network

/// How a request's body is framed.
enum BodyFraming: Equatable {
    case none
    case length(Int)
    case chunked
    case unknown
}

/// A request head rewritten for the server's `/app/{name}` route.
struct RewrittenHead: Equatable {
    /// Head bytes to send upstream (ending in CRLF CRLF).
    let head: Data
    /// How the request body is framed.
    let framing: BodyFraming
    /// Whether the client asked for a protocol upgrade (WebSocket).
    let isUpgrade: Bool
}

/// Pure HTTP helpers for the tunnel. Kept UIKit/Network-free so they can be
/// unit-tested.
enum ProxyHTTP {
    /// Index just past the head's terminating CRLF CRLF, if present.
    static func headEnd(in data: Data) -> Int? {
        data.range(of: Data("\r\n\r\n".utf8))?.upperBound
    }

    /// Rewrite a request line `/x` → `/app/<name>/x` and fix connection
    /// semantics: upgraded (WebSocket) requests keep their upgrade, everything
    /// else is forced to `Connection: close` so the response is EOF-delimited.
    static func rewriteHead(_ head: Data, appName: String) -> RewrittenHead? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])
        let version = String(parts[2])
        let mapped = "/app/\(appName)" + (path.hasPrefix("/") ? path : "/" + path)

        var isUpgrade = false
        var contentLength: Int?
        var chunked = false
        var headers: [String] = []

        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "connection":
                if value.lowercased().contains("upgrade") { isUpgrade = true }
                continue // replaced below
            case "upgrade":
                isUpgrade = true
            case "content-length":
                contentLength = Int(value)
            case "transfer-encoding":
                if value.lowercased().contains("chunked") { chunked = true }
            default:
                break
            }
            headers.append(line)
        }

        headers.append(isUpgrade ? "Connection: Upgrade" : "Connection: close")

        let framing: BodyFraming
        if chunked {
            framing = .chunked
        } else if let contentLength {
            framing = .length(contentLength)
        } else {
            framing = .none
        }

        let rebuilt = ([ "\(method) \(mapped) \(version)" ] + headers)
            .joined(separator: "\r\n") + "\r\n\r\n"
        return RewrittenHead(head: Data(rebuilt.utf8), framing: framing, isUpgrade: isUpgrade)
    }

    /// If a response head+body is one of our small JSON errors, return a
    /// readable HTML page instead. Returns `nil` to pass the bytes through.
    static func errorPageInsteadOfJSON(head: Data, body: Data) -> Data? {
        guard let headText = String(data: head, encoding: .utf8),
              let statusLine = headText.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]), status >= 400 else { return nil }

        struct ServerError: Decodable {
            let error: String
            let hint: String?
        }
        guard let server = try? JSONDecoder().decode(ServerError.self, from: body) else {
            return nil
        }
        return errorPage(
            status: status,
            reason: reason(for: status),
            message: server.error,
            hint: server.hint
        )
    }

    /// A minimal, readable HTML error response for the web view.
    static func errorPage(status: Int, reason: String, message: String, hint: String?) -> Data {
        let hintHTML = hint.map { "<p class=\"hint\">\(escape($0))</p>" } ?? ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(message))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, system-ui, sans-serif; margin: 0;
               display: flex; min-height: 100vh; align-items: center;
               justify-content: center; text-align: center; padding: 24px; }
        .card { max-width: 30rem; }
        h1 { font-size: 1.25rem; font-weight: 600; }
        .hint { opacity: 0.65; }
        </style></head>
        <body><div class="card">
        <h1>\(escape(message))</h1>
        \(hintHTML)
        <p class="hint">\(status) \(escape(reason))</p>
        </div></body></html>
        """
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        case 504: return "Gateway Timeout"
        default: return "Error"
        }
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Streams one loopback HTTP connection to a serve stream and back.
///
/// Unlike a request/response relay, this pumps bytes **both** ways, so
/// responses stream (video/SSE/chunked), uploads stream, and upgraded
/// connections (WebSocket) tunnel through untouched.
nonisolated final class ProxyTunnel: @unchecked Sendable {
    private let connection: NWConnection
    private let appName: String
    private let service: IrohService

    /// Largest request head we'll buffer before giving up.
    private static let maxHeadBytes = 64 * 1024
    /// Largest error body we'll buffer to swap for an HTML page.
    private static let maxErrorBytes = 64 * 1024

    init(connection: NWConnection, appName: String, service: IrohService) {
        self.connection = connection
        self.appName = appName
        self.service = service
    }

    func start() async {
        guard let (headData, rest) = try? await readRequestHead(),
              let rewritten = ProxyHTTP.rewriteHead(headData, appName: appName)
        else {
            await sendError(status: 400, reason: "Bad Request", message: "The app request looked malformed.", hint: nil)
            return
        }

        let stream: IrohService.RawStream
        do {
            stream = try await service.openStream()
        } catch {
            await sendError(
                status: 502,
                reason: "Bad Gateway",
                message: "Couldn't reach the app.",
                hint: "\(error)"
            )
            return
        }

        do {
            try await stream.send.writeAll(buf: rewritten.head)
        } catch {
            connection.cancel()
            return
        }

        if rewritten.isUpgrade {
            // Tunnel both directions until either side closes.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.pumpToServer(send: stream.send, initial: rest) }
                group.addTask { await self.pumpToClient(recv: stream.recv) }
            }
            return
        }

        // Upload the (possibly streamed) request body, then finish the send half.
        do {
            try await uploadBody(rest, framing: rewritten.framing, send: stream.send)
            try await stream.send.finish()
        } catch {
            connection.cancel()
            return
        }

        await pumpToClient(recv: stream.recv)
    }

    // MARK: - Reading the request

    private func readRequestHead() async throws -> (head: Data, rest: Data)? {
        var buffer = Data()
        while true {
            if let end = ProxyHTTP.headEnd(in: buffer) {
                return (Data(buffer.prefix(end)), Data(buffer.suffix(from: end)))
            }
            if buffer.count > Self.maxHeadBytes { return nil }
            let (chunk, isComplete) = try await connection.receiveChunk(maxLength: 16 * 1024)
            buffer.append(chunk)
            if isComplete && ProxyHTTP.headEnd(in: buffer) == nil { return nil }
        }
    }

    // MARK: - Pumps

    /// Send the request body (framed per `framing`) and return.
    private func uploadBody(_ initial: Data, framing: BodyFraming, send: SendStream) async throws {
        switch framing {
        case .none:
            // Nothing to send beyond the head.
            break

        case .length(let length):
            var remaining = length
            if !initial.isEmpty, remaining > 0 {
                let take = Data(initial.prefix(remaining))
                try await send.writeAll(buf: take)
                remaining -= take.count
            }
            while remaining > 0 {
                let (chunk, isComplete) = try await connection.receiveChunk(
                    maxLength: min(65536, remaining)
                )
                if chunk.isEmpty {
                    if isComplete { break } else { continue }
                }
                try await send.writeAll(buf: chunk)
                remaining -= chunk.count
            }

        case .chunked:
            try await sendChunkedBody(initial, send: send)

        case .unknown:
            try await sendUntilClosed(initial, send: send)
        }
    }

    private func sendChunkedBody(_ initial: Data, send: SendStream) async throws {
        let terminator = Data("\r\n0\r\n\r\n".utf8)
        var tail = initial
        if !initial.isEmpty {
            try await send.writeAll(buf: initial)
            if containsTerminator(tail, terminator) { return }
        }
        while true {
            let (chunk, isComplete) = try await connection.receiveChunk(maxLength: 65536)
            if !chunk.isEmpty {
                try await send.writeAll(buf: chunk)
                tail.append(chunk)
            }
            if containsTerminator(tail, terminator) { return }
            if isComplete { return }
        }
    }

    private func sendUntilClosed(_ initial: Data, send: SendStream) async throws {
        if !initial.isEmpty {
            try await send.writeAll(buf: initial)
        }
        while true {
            let (chunk, isComplete) = try await connection.receiveChunk(maxLength: 65536)
            if !chunk.isEmpty {
                _ = try await send.write(buf: chunk)
            }
            if isComplete { return }
        }
    }

    /// Look for the chunked terminator in the tail; also accept `0\r\n\r\n`
    /// with no leading CRLF (single, first chunk).
    private func containsTerminator(_ data: Data, _ terminator: Data) -> Bool {
        if data.range(of: terminator) != nil { return true }
        // A body that is exactly one empty chunk: "0\r\n\r\n".
        return data == Data("0\r\n\r\n".utf8)
    }

    /// iroh → client until the stream ends.
    private func pumpToClient(recv: RecvStream) async {
        // Peek the response head so our small JSON errors can be shown as HTML.
        var buffer = Data()
        while ProxyHTTP.headEnd(in: buffer) == nil {
            let chunk: Data
            do {
                chunk = try await recv.read(sizeLimit: 16 * 1024)
            } catch {
                break
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > Self.maxErrorBytes { break }
        }

        if let end = ProxyHTTP.headEnd(in: buffer),
           let page = ProxyHTTP.errorPageInsteadOfJSON(
               head: Data(buffer.prefix(end)),
               body: Data(buffer.suffix(from: end))
           ) {
            try? await connection.sendChunk(page)
            await connection.finishSending()
            connection.cancel()
            return
        }

        if !buffer.isEmpty {
            do {
                try await connection.sendChunk(buffer)
            } catch {
                connection.cancel()
                return
            }
        }

        while true {
            let chunk: Data
            do {
                chunk = try await recv.read(sizeLimit: 65536)
            } catch {
                break
            }
            if chunk.isEmpty { break }
            do {
                try await connection.sendChunk(chunk)
            } catch {
                break
            }
        }
        await connection.finishSending()
        connection.cancel()
    }

    /// client → iroh until the client closes.
    private func pumpToServer(send: SendStream, initial: Data) async {
        if !initial.isEmpty {
            do {
                try await send.writeAll(buf: initial)
            } catch {
                return
            }
        }
        while true {
            let (chunk, isComplete): (Data, Bool)
            do {
                (chunk, isComplete) = try await connection.receiveChunk(maxLength: 65536)
            } catch {
                break
            }
            if !chunk.isEmpty {
                do {
                    _ = try await send.write(buf: chunk)
                } catch {
                    break
                }
            }
            if isComplete { break }
        }
        try? await send.finish()
    }

    private func sendError(status: Int, reason: String, message: String, hint: String?) async {
        let page = ProxyHTTP.errorPage(status: status, reason: reason, message: message, hint: hint)
        try? await connection.sendChunk(page)
        await connection.finishSending()
        connection.cancel()
    }
}

private extension NWConnection {
    /// Receive once, returning the bytes and whether the peer finished sending.
    func receiveChunk(maxLength: Int) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }

    /// Send one chunk and wait for it to be processed.
    func sendChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Half-close the send side (FIN).
    func finishSending() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }
}
