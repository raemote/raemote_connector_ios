import Testing
import Foundation
import WebKit
@testable import Raemote_Connector

struct ProxyAuthTests {

    private func head(_ headers: [String]) -> Data {
        Data((["GET / HTTP/1.1", "Host: 127.0.0.1:5000"] + headers + ["", ""])
            .joined(separator: "\r\n")
            .utf8)
    }

    private let secret = "a" * 64

    // MARK: - check

    @Test func acceptsTheCookie() {
        let h = head(["Cookie: other=1; \(ProxyAuth.cookieName)=\(secret)"])
        #expect(ProxyAuth.check(head: h, secret: secret))
    }

    @Test func acceptsTheHeader() {
        let h = head(["\(ProxyAuth.headerName): \(secret)"])
        #expect(ProxyAuth.check(head: h, secret: secret))
    }

    @Test func headerNamesAreCaseInsensitive() {
        let h = head(["cookie: \(ProxyAuth.cookieName)=\(secret)",
                      "x-raemote-session: \(secret)"])
        #expect(ProxyAuth.check(head: h, secret: secret))
    }

    @Test func rejectsMissingCredentials() {
        #expect(!ProxyAuth.check(head: head(["Cookie: session=abc"]), secret: secret))
        #expect(!ProxyAuth.check(head: head([]), secret: secret))
    }

    @Test func rejectsWrongValues() {
        let wrongCookie = head(["Cookie: \(ProxyAuth.cookieName)=\(String(repeating: "b", count: 64))"])
        #expect(!ProxyAuth.check(head: wrongCookie, secret: secret))

        let wrongHeader = head(["\(ProxyAuth.headerName): deadbeef"])
        #expect(!ProxyAuth.check(head: wrongHeader, secret: secret))

        // Right value under a different cookie's name is still no.
        let otherName = head(["Cookie: raemote_other=\(secret)"])
        #expect(!ProxyAuth.check(head: otherName, secret: secret))
    }

    @Test func rejectsGarbageHeads() {
        #expect(!ProxyAuth.check(head: Data("not http".utf8), secret: secret))
        #expect(!ProxyAuth.check(head: Data(), secret: secret))
        #expect(!ProxyAuth.check(head: Data([0xC3, 0x28, 0xA0, 0xA1]), secret: secret))
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

    // MARK: - cookie installation

    @Test func installCookiePutsTheSecretInTheWebViewStore() async {
        await ProxyAuth.installCookie()
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let gate = cookies.first {
            $0.name == ProxyAuth.cookieName && $0.domain == "127.0.0.1"
        }
        #expect(gate?.value == ProxyAuth.secret)
        #expect(gate?.path == "/")
        #expect(gate.map { $0.value.count } == 64)
    }
}

private extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
