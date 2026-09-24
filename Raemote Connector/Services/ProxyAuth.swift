import Foundation
import WebKit

/// The secret gate in front of the loopback proxy.
///
/// iOS does not isolate loopback between apps: any process on the phone can
/// connect to `127.0.0.1:<port>` and would otherwise ride this app's
/// authorized iroh tunnel to the paired server. The gate closes that: every
/// request head must present this launch's 256-bit secret — as the
/// `raemote_auth` cookie (what `WKWebsiteDataStore` carries automatically) or
/// as the `X-Raemote-Session` header (what our own `URLSession` fetches send,
/// since `URLSession` has a different cookie store than the web view) — and
/// the tunnel answers 403 to anything else without opening an iroh stream.
///
/// The cookie is installed into `WKWebsiteDataStore.default()` **before** the
/// first proxy URL loads, so the web view presents it from its very first
/// request. Cookies are scoped by domain, not port: one secret covers every
/// running session's port, which is exactly what we want (and why the secret
/// is per *launch*, not per session — sessions come and go, the cookie stays).
nonisolated enum ProxyAuth {
    /// Cookie the web view presents on every same-origin request.
    static let cookieName = "raemote_auth"
    /// Header our own `URLSession` requests present (`URLSession` does not
    /// share the web view's cookie store).
    static let headerName = "X-Raemote-Session"

    /// 256 bits of hex, fresh for this launch; overwritten into the cookie
    /// store before each session's first load.
    static let secret: String = {
        var rng = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }
            .joined()
    }()

    /// Put the secret into the web view's cookie store. Idempotent (same
    /// value every call within a launch); must complete before the first
    /// proxy URL is handed to the web view.
    ///
    /// `HttpOnly` is deliberately not set: `HTTPCookie` exposes no creation
    /// key for it on iOS, and the threat it would mitigate (the remote page's
    /// own JS reading the secret) is already inside the tunnel — the gate's
    /// job is keeping *other apps on this phone* out, and they never receive
    /// the cookie at all.
    @MainActor
    static func installCookie() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName,
            .value: secret,
            .path: "/",
            .domain: "127.0.0.1",
            .secure: "FALSE",
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    /// Whether a raw request head carries the launch's secret.
    static func isAuthorized(head: Data) -> Bool {
        check(head: head, secret: secret)
    }

    /// Pure check over a raw HTTP request head: any presented credential
    /// (cookie pair or header) that matches `secret` authorizes the request.
    /// Compared in constant time; a failed comparison never short-circuits
    /// the scan, and success is the only early return.
    static func check(head: Data, secret: String) -> Bool {
        guard let text = String(data: head, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon]
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "cookie":
                for pair in value.split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let cookieNameFromWire = kv[0].trimmingCharacters(in: .whitespaces)
                    guard cookieNameFromWire == cookieName else { continue }
                    if constantTimeEquals(String(kv[1]), secret) { return true }
                }
            case headerName.lowercased():
                if constantTimeEquals(value, secret) { return true }
            default:
                break
            }
        }
        return false
    }

    /// Length-aware constant-time string comparison (the value is the secret;
    /// a byte-by-byte `==` could leak its prefix through timing).
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}
