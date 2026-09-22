import Testing
import Foundation
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

    /// Our error pages are marked in the response, so the web view can tell
    /// them apart from the app's own pages without matching title text.
    @Test func errorPageCarriesTheMarkerHeader() {
        let page = ProxyHTTP.errorPage(
            status: 504,
            reason: "Gateway Timeout",
            message: "The app didn't respond.",
            hint: nil
        )
        let text = String(decoding: page, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n").first ?? ""
        #expect(head.contains("\(ProxyHTTP.errorMarkerHeader): 1"))

        // The JSON→HTML swap routes through the same builder, so it is marked
        // too (it uses the server's own error message as the title).
        let jsonBody = Data(#"{"error":"unknown app \"x\"","hint":"refresh"}"#.utf8)
        let headBytes = Data("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n".utf8)
        let swapped = ProxyHTTP.errorPageInsteadOfJSON(head: headBytes, body: jsonBody)
        let swappedHead = String(decoding: swapped ?? Data(), as: UTF8.self)
            .components(separatedBy: "\r\n\r\n").first ?? ""
        #expect(swappedHead.contains("\(ProxyHTTP.errorMarkerHeader): 1"))
    }
}
