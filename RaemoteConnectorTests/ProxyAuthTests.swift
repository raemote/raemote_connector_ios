import Testing
import Foundation
@testable import Raemote_Connector

struct ProxyAuthTests {

    private func head(requestLine: String = "GET / HTTP/1.1", _ headers: [String] = []) -> Data {
        Data(([requestLine, "Host: 127.0.0.1:5000"] + headers + ["", ""])
            .joined(separator: "\r\n")
            .utf8)
    }

    private let secret = "a" * 64

    // MARK: - match

    @Test func acceptsTheCookie() {
        let h = head(["Cookie: other=1; \(ProxyAuth.cookieName)=\(secret)"])
        #expect(ProxyAuth.match(head: h, secret: secret) == .cookie)
    }

    @Test func acceptsTheQuerySecretOnTheRequestLine() {
        let h = head(requestLine: "GET /?raemote_auth=\(secret) HTTP/1.1")
        #expect(ProxyAuth.match(head: h, secret: secret) == .query)
    }

    @Test func acceptsTheQuerySecretAmongOtherParameters() {
        let h = head(requestLine: "GET /some/path?token=xyz&raemote_auth=\(secret)&x=1 HTTP/1.1")
        #expect(ProxyAuth.match(head: h, secret: secret) == .query)
    }

    @Test func cookieNamesAreCaseInsensitiveOnTheWire() {
        let h = head(["cookie: \(ProxyAuth.cookieName)=\(secret)"])
        #expect(ProxyAuth.match(head: h, secret: secret) == .cookie)
    }

    @Test func rejectsMissingCredentials() {
        #expect(ProxyAuth.match(head: head(["Cookie: session=abc"]), secret: secret) == .none)
        #expect(ProxyAuth.match(head: head([]), secret: secret) == .none)
        #expect(ProxyAuth.match(head: head(requestLine: "GET / HTTP/1.1"), secret: secret) == .none)
    }

    @Test func rejectsWrongValues() {
        let wrongCookie = head(["Cookie: \(ProxyAuth.cookieName)=\(String(repeating: "b", count: 64))"])
        #expect(ProxyAuth.match(head: wrongCookie, secret: secret) == .none)

        let wrongQuery = head(requestLine: "GET /?raemote_auth=deadbeef HTTP/1.1")
        #expect(ProxyAuth.match(head: wrongQuery, secret: secret) == .none)

        // Right value under a different cookie's name is still no.
        let otherName = head(["Cookie: raemote_other=\(secret)"])
        #expect(ProxyAuth.match(head: otherName, secret: secret) == .none)
    }

    @Test func rejectsGarbageHeads() {
        #expect(ProxyAuth.match(head: Data("not http".utf8), secret: secret) == .none)
        #expect(ProxyAuth.match(head: Data(), secret: secret) == .none)
        #expect(ProxyAuth.match(head: Data([0xC3, 0x28, 0xA0, 0xA1]), secret: secret) == .none)
    }

    @Test func isAuthorizedMirrorsMatchAgainstTheLaunchSecret() {
        #expect(ProxyAuth.isAuthorized(head: head(["Cookie: \(ProxyAuth.cookieName)=\(ProxyAuth.secret)"])))
        #expect(ProxyAuth.isAuthorized(head: head(requestLine: "GET /?raemote_auth=\(ProxyAuth.secret) HTTP/1.1")))
        #expect(!ProxyAuth.isAuthorized(head: head([])))
        #expect(!ProxyAuth.isAuthorized(head: head(requestLine: "GET /?raemote_auth=wrong HTTP/1.1")))
    }

    // MARK: - constant-time comparison

    @Test func constantTimeEqualsMatchesEquality() {
        #expect(ProxyAuth.constantTimeEquals("abc", "abc"))
        #expect(!ProxyAuth.constantTimeEquals("abc", "abd"))
        #expect(!ProxyAuth.constantTimeEquals("abc", "ab"))
        #expect(!ProxyAuth.constantTimeEquals("", "a"))
        #expect(ProxyAuth.constantTimeEquals("", ""))
        #expect(ProxyAuth.constantTimeEquals("多字节", "多字节"))
        #expect(!ProxyAuth.constantTimeEquals("多字节", "多字节节"))
    }

    // MARK: - secret

    @Test func secretIs256BitsOfHex() {
        #expect(ProxyAuth.secret.count == 64)
        #expect(ProxyAuth.secret.allSatisfy { $0.isHexDigit })
    }

    // MARK: - authorizedURL

    @Test func authorizedURLAppendsTheSecret() throws {
        let url = try #require(URL(string: "http://127.0.0.1:5000/?token=abc"))
        let authorized = ProxyAuth.authorizedURL(url)
        let items = URLComponents(url: authorized, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "token" })?.value == "abc")
        #expect(items?.first(where: { $0.name == ProxyAuth.queryItemName })?.value == ProxyAuth.secret)
    }

    @Test func authorizedURLReplacesAStaleSecret() throws {
        let url = try #require(URL(string: "http://127.0.0.1:5000/?\(ProxyAuth.queryItemName)=old"))
        let authorized = ProxyAuth.authorizedURL(url)
        let items = URLComponents(url: authorized, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let secrets = items.filter { $0.name == ProxyAuth.queryItemName }
        #expect(secrets.count == 1)
        #expect(secrets.first?.value == ProxyAuth.secret)

        // The URL this produces would authenticate as a query match.
        let target = "/" + (authorized.query.map { "?\($0)" } ?? "")
        let h = Data("GET \(target) HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        #expect(ProxyAuth.match(head: h, secret: ProxyAuth.secret) == .query)
    }
}

private extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
