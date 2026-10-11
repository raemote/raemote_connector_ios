import Testing
import Foundation
import Network
@testable import Raemote_Connector

struct ProxyHTTPTests {

    // MARK: - headEnd

    @Test func headEndFindsTerminator() {
        #expect(ProxyHTTP.headEnd(in: Data("GET / HTTP/1.1\r\nHost: x".utf8)) == nil)
        let data = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY".utf8)
        #expect(ProxyHTTP.headEnd(in: data) == 27)
    }

    // MARK: - rewriteHead

    private func rewrite(_ request: String) -> RewrittenHead? {
        ProxyHTTP.rewriteHead(Data(request.utf8), appName: "app_name")
    }

    @Test func rewriteMapsPathAndForcesClose() throws {
        let head = try #require(rewrite("GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n"))
        let text = String(decoding: head.head, as: UTF8.self)
        #expect(text.hasPrefix("GET /app/app_name/index.html HTTP/1.1\r\n"))
        #expect(text.contains("Connection: close"))
        #expect(head.framing == .none)
        #expect(!head.isUpgrade)
    }

    @Test func rewriteKeepsQueryAndRoot() throws {
        let head = try #require(rewrite("GET /assets/main.js?v=3 HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(String(decoding: head.head, as: UTF8.self)
            .hasPrefix("GET /app/app_name/assets/main.js?v=3 HTTP/1.1\r\n"))
    }

    @Test func rewriteDoesNotDuplicateConnection() throws {
        let head = try #require(rewrite("GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"))
        let text = String(decoding: head.head, as: UTF8.self)
        let count = text.components(separatedBy: "Connection:").count - 1
        #expect(count == 1)
        #expect(text.contains("Connection: close"))
    }

    @Test func rewritePreservesUpgrade() throws {
        let request = "GET /socket HTTP/1.1\r\nHost: x\r\n"
            + "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\n\r\n"
        let head = try #require(rewrite(request))
        let text = String(decoding: head.head, as: UTF8.self)
        #expect(head.isUpgrade)
        #expect(text.contains("Connection: Upgrade"))
        #expect(text.contains("Upgrade: websocket"))
        #expect(text.contains("Sec-WebSocket-Key: abc"))
        #expect(!text.contains("Connection: close"))
    }

    @Test func rewriteDetectsBodyFraming() throws {
        let length = try #require(rewrite("POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"))
        #expect(length.framing == .length(5))
        #expect(length.isUpgrade == false)

        let chunked = try #require(rewrite("POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"))
        #expect(chunked.framing == .chunked)
    }

    @Test func rewritePreservesBodyBytes() throws {
        let head = try #require(rewrite("POST /submit HTTP/1.1\r\nContent-Length: 3\r\n\r\n"))
        // The head ends at CRLFCRLF; the body is read separately by the tunnel.
        #expect(String(decoding: head.head, as: UTF8.self).hasSuffix("\r\n\r\n"))
    }

    // MARK: - gate secret stripping

    @Test func rewriteStripsTheGateQueryFromThePath() throws {
        let request = "GET /?raemote_auth=SECRET&token=abc HTTP/1.1\r\nHost: x\r\n\r\n"
        let head = try #require(rewrite(request))
        let text = String(decoding: head.head, as: UTF8.self)
        #expect(text.hasPrefix("GET /app/app_name/?token=abc HTTP/1.1\r\n"))
        #expect(!text.contains("raemote_auth"))
        #expect(text.contains("token=abc"))
    }

    @Test func rewriteKeepsThePathWhenThereIsNoGateQuery() throws {
        let head = try #require(rewrite("GET /?token=abc HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(String(decoding: head.head, as: UTF8.self)
            .hasPrefix("GET /app/app_name/?token=abc HTTP/1.1\r\n"))
    }

    @Test func rewriteStripsTheGateQueryFromReferer() throws {
        let request = "GET / HTTP/1.1\r\nHost: x\r\n"
            + "Referer: http://127.0.0.1:5000/?\(ProxyAuth.queryItemName)=SECRET&x=1\r\n\r\n"
        let head = try #require(rewrite(request))
        let text = String(decoding: head.head, as: UTF8.self)
        #expect(text.contains("Referer: http://127.0.0.1:5000/?x=1"))
        #expect(!text.contains("raemote_auth"))
    }

    // MARK: - gate cookie bootstrap

    @Test func injectsTheGateCookieAfterTheStatusLine() {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        let out = ProxyHTTP.injectingGateCookie(into: response, secret: "s3cret")
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Set-Cookie: \(ProxyAuth.cookieName)=s3cret; Path=/;"))
        #expect(text.contains("Content-Length: 0\r\n\r\n"))
    }

    @Test func injectingIntoAHeadWithoutANewlineIsANoOp() {
        let response = Data("HTTP/1.1 200 OK".utf8)
        #expect(ProxyHTTP.injectingGateCookie(into: response, secret: "s") == response)
    }

    // MARK: - error page substitution

    private func response(status: Int, reason: String, body: String) -> (Data, Data) {
        let head = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n".utf8)
        return (head, Data(body.utf8))
    }

    @Test func jsonErrorBecomesHtml() throws {
        let (head, body) = response(
            status: 404,
            reason: "Not Found",
            body: "{\"error\":\"unknown app \\\"jellyfin\\\"\",\"hint\":\"refresh the list\"}"
        )
        let page = try #require(ProxyHTTP.errorPageInsteadOfJSON(head: head, body: body))
        let text = String(decoding: page, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(text.contains("text/html"))
        #expect(text.contains("unknown app"))
        #expect(text.contains("refresh the list"))
    }

    @Test func realErrorBodyPassesThrough() {
        // A 404 from the app itself is not our JSON shape → leave it alone.
        let (head, body) = response(status: 404, reason: "Not Found", body: "<html>nope</html>")
        #expect(ProxyHTTP.errorPageInsteadOfJSON(head: head, body: body) == nil)
    }

    @Test func successPassesThrough() {
        let (head, body) = response(status: 200, reason: "OK", body: "{\"ok\":true}")
        #expect(ProxyHTTP.errorPageInsteadOfJSON(head: head, body: body) == nil)
    }

    @Test func errorPageEscapesHtml() {
        let page = ProxyHTTP.errorPage(
            status: 502,
            reason: "Bad Gateway",
            message: "couldn't reach <the app>",
            hint: "a & b"
        )
        let text = String(decoding: page, as: UTF8.self)
        #expect(text.contains("&lt;the app&gt;"))
        #expect(text.contains("a &amp; b"))
    }
}

/// Regression cover for the loopback proxy's tunnel registry.
///
/// TestFlight build 8 died on iPad with `EXC_BAD_ACCESS` inside
/// `Dictionary.removeValue(forKey:)`: a tunnel's pump ended on a Swift
/// cooperative thread and untracked itself there, while the listener queue was
/// tracking a new connection or tearing everything down — two threads mutating
/// `tunnels` at once, one of them freeing the storage the other was refcounting.
/// The fix routes both registry mutations through the owning queue.
///
/// The crash was a race, so the test that guards it must be run under Thread
/// Sanitizer to mean anything:
/// `xcodebuild test -enableThreadSanitizer YES …`
@MainActor
struct LocalProxyServerRegistryTests {

    private func makeServer() -> LocalProxyServer {
        LocalProxyServer(
            nodeId: "server-a",
            appName: "jellyfin",
            // Never dialled: the gate rejects these requests before any iroh
            // stream opens, so this is just a cheap, unconnected service.
            service: IrohService(monitor: IrohConnectionMonitor())
        )
    }

    @Test func pumpsEndingWhileConnectionsArriveDoNotCorruptTheRegistry() async throws {
        let server = makeServer()
        let port = try await server.start()
        let endpoint = NWEndpoint.Host.ipv4(.loopback)
        let clients = DispatchQueue(label: "test.clients")

        // Accept-and-abandon, round after round. The part that matters is
        // cancelling *inside* the loop: each pump then unwinds — untracking
        // itself on a cooperative thread — while later rounds are still being
        // tracked on the listener queue. That unordered pair is what build 8
        // lost, one thread freeing the dictionary storage the other was
        // refcounting. Leaving them all open until the end would not reproduce
        // it: the teardown happens-before every unwind.
        var stillOpen: [NWConnection] = []
        var sawTracked = false
        for i in 0..<60 {
            let client = NWConnection(
                host: endpoint,
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            client.start(queue: clients)
            try await Task.sleep(for: .milliseconds(2))
            if i < 10 { stillOpen.append(client) } else { client.cancel() }
            if !sawTracked { sawTracked = server.trackedTunnelCount > 0 }
        }
        #expect(sawTracked, "connections should have been tracked while pumping")

        // Teardown then overlaps with whatever is still ending: `stop()` cancels
        // every tracked connection on the queue while their pumps unwind.
        server.stop()
        stillOpen.forEach { $0.cancel() }

        // And the fence holds: nothing is left tracked once every pump ended.
        var tracked = server.trackedTunnelCount
        for _ in 0..<100 where tracked > 0 {
            try await Task.sleep(for: .milliseconds(20))
            tracked = server.trackedTunnelCount
        }
        #expect(tracked == 0)
    }

    @Test func stopIsSafeWithNoConnectionsAndRepeatable() async throws {
        let server = makeServer()
        _ = try await server.start()
        server.stop()
        // Idempotent: closing twice (close() plus an eviction fence) must not
        // wedge the registry or double-release anything.
        server.stop()
        #expect(server.trackedTunnelCount == 0)
    }
}
