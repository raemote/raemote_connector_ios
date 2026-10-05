import Foundation

/// The secret gate in front of the loopback proxy.
///
/// iOS does not isolate loopback between apps: any process on the phone can
/// connect to `127.0.0.1:<port>` and would otherwise ride this app's
/// authorized iroh tunnel to the paired server. The gate closes that: every
/// request head must present this launch's 256-bit secret — as the
/// `raemote_auth` cookie, or as the `raemote_auth` query item on the launch
/// URL — and the tunnel answers 403 to anything else without opening an iroh
/// stream.
///
/// `SFSafariViewController` shares *Safari's* cookie store, which no API in
/// this app can write to, so the cookie cannot be pre-installed the way the
/// old `WKWebView` stack did. Instead the launch URL carries the secret; when
/// the tunnel sees it, it answers with a `Set-Cookie` the browser retains for
/// every later request (and strips the secret before it reaches the app).
/// Cookies are scoped by domain, not port: one secret covers every running
/// session's port, which is exactly what we want (and why the secret is per
/// *launch*, not per session — sessions come and go, the cookie stays).
nonisolated enum ProxyAuth {
    /// Cookie the browser presents on every same-origin request once the
    /// launch URL has bootstrapped it.
    static let cookieName = "raemote_auth"
    /// Query item carrying the secret on the launch URL (same name, so the
    /// bootstrap and the cookie read as one credential).
    static let queryItemName = "raemote_auth"
    /// How long the injected cookie lives. The secret rotates every launch, so
    /// an old cookie simply fails the constant-time check; a fixed lifetime
    /// just has to outlive a normal browsing session (session cookies may be
    /// dropped when the Safari view controller goes away).
    static let cookieMaxAgeSeconds = 30 * 24 * 60 * 60

    /// 256 bits of hex, fresh for this launch; seeded into the browser's
    /// cookie store by the first response to the launch URL.
    static let secret: String = {
        var rng = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }
            .joined()
    }()

    /// How a request head presented the secret.
    enum Match: Equatable, Sendable {
        /// No usable credential — the request must be rejected.
        case none
        /// The `raemote_auth` cookie (later requests, once bootstrapped).
        case cookie
        /// The `raemote_auth` query item (the launch URL's first request).
        case query
    }

    /// Whether a raw request head carries the launch's secret, and how.
    static func match(head: Data, secret: String) -> Match {
        guard let text = String(data: head, encoding: .utf8) else { return .none }
        let lines = text.components(separatedBy: "\r\n")

        // The request line: `GET /path?raemote_auth=… HTTP/1.1`.
        if let requestLine = lines.first {
            let parts = requestLine.split(separator: " ", maxSplits: 2)
            if parts.count >= 2,
               let presented = queryValue(named: queryItemName, inPath: String(parts[1])),
               constantTimeEquals(presented, secret) {
                return .query
            }
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon]
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if name.lowercased() == "cookie" {
                for pair in value.split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let cookieNameFromWire = kv[0].trimmingCharacters(in: .whitespaces)
                    guard cookieNameFromWire == cookieName else { continue }
                    if constantTimeEquals(String(kv[1]), secret) { return .cookie }
                }
            }
        }
        return .none
    }

    /// Whether a raw request head carries the launch's secret at all.
    static func isAuthorized(head: Data) -> Bool {
        match(head: head, secret: secret) != .none
    }

    /// The launch URL: `url` with the secret added as a query item (replacing
    /// any stale one), so the browser's first request through a fresh session
    /// bootstraps the cookie.
    static func authorizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == queryItemName }
        items.append(URLQueryItem(name: queryItemName, value: secret))
        components.queryItems = items
        return components.url ?? url
    }

    /// The value of `name` in a request target's query (`/path?name=value`),
    /// or `nil` when absent. Percent-decoded so a mangled encoding never
    /// accidentally matches.
    private static func queryValue(named name: String, inPath path: String) -> String? {
        guard let q = path.firstIndex(of: "?") else { return nil }
        let rest = path[path.index(after: q)...]
        for pair in rest.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, String(kv[0]) == name else { continue }
            let raw = String(kv[1])
            return raw.removingPercentEncoding ?? raw
        }
        return nil
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
