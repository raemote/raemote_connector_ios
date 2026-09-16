import Foundation

/// Remembers an optional launch path/query for an app, so opening it can carry
/// one-time credentials the app expects in its entry URL.
///
/// Some local apps authenticate their index with a token that is only printed
/// on the server's console — the tool prints a URL such as
/// `http://127.0.0.1:3080/?token=…`, which it exchanges for a session cookie.
/// Raemote's proxy is transparent, but the phone opens `/` and never sees that
/// token, so the app answers 401. Pasting the printed URL here makes the web
/// view open `/app/<name>/<path>?<query>` once; the app's redirect and
/// `Set-Cookie` then flow through the proxy as usual and the session persists.
///
/// Launch paths are keyed by **server node id + app name**, matching
/// `ProxyPortStore`: two servers running identically-named apps must never
/// share one.
enum AppLaunchStore {
    private static let storageKey = "appLaunchPaths"
    /// A generous cap; tokens and paths are short.
    private static let maxLength = 2048

    private static func entryKey(nodeId: String, app: String) -> String {
        "\(nodeId)/\(app)"
    }

    /// The stored launch path (`/…?…`) for an app, if any.
    static func path(
        nodeId: String,
        app: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        let map = defaults.dictionary(forKey: storageKey) as? [String: String]
        return map?[entryKey(nodeId: nodeId, app: app)]
    }

    /// Every stored launch path for one server, keyed by app name.
    static func paths(
        nodeId: String,
        defaults: UserDefaults = .standard
    ) -> [String: String] {
        guard let map = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            return [:]
        }
        let prefix = "\(nodeId)/"
        var result: [String: String] = [:]
        for (key, value) in map where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    /// Store a launch path. An empty (or unusable) input clears the entry.
    /// Returns the stored path, or `nil` when the entry was cleared.
    @discardableResult
    static func remember(
        _ rawInput: String,
        nodeId: String,
        app: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        var map = (defaults.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        let key = entryKey(nodeId: nodeId, app: app)
        defer { defaults.set(map, forKey: storageKey) }

        guard let normalized = normalized(rawInput) else {
            map.removeValue(forKey: key)
            return nil
        }
        map[key] = normalized
        return normalized
    }

    /// Turn whatever the user pasted into a path + query that starts with `/`.
    ///
    /// Accepts a whole URL (`http://127.0.0.1:3080/?token=x`), a bare query
    /// (`?token=x`), a bare token pair (`token=x`), a host with a query
    /// (`127.0.0.1:3080/?token=x`), or a plain path. Returns `nil` for input
    /// that carries nothing (empty, or just `/`).
    static func normalized(_ rawInput: String) -> String? {
        var input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= maxLength else { return nil }
        if let fragment = input.firstIndex(of: "#") { input = String(input[..<fragment]) }
        guard !input.isEmpty else { return nil }

        // Parsed by hand rather than with `URL`: `URL.path` normalizes away a
        // trailing slash, which can change an app's route (`/app/` vs `/app`).
        let path: String
        if let scheme = input.range(of: "://") {
            // A whole URL: keep just the path and query after the authority.
            let afterAuthority = input[scheme.upperBound...]
            if let slash = afterAuthority.firstIndex(of: "/") {
                path = String(afterAuthority[slash...])
            } else if let query = afterAuthority.firstIndex(of: "?") {
                path = "/" + String(afterAuthority[query...])
            } else {
                return nil
            }
        } else if input.hasPrefix("/") {
            path = input
        } else if input.hasPrefix("?") {
            path = "/" + input
        } else if input.contains("="), !input.contains("/"), !input.contains(" ") {
            // A bare `token=…` / `a=b&c=d` query.
            path = "/?" + input
        } else if let slash = input.firstIndex(of: "/") {
            // `host:port/path` or `host/path`.
            path = String(input[slash...])
        } else {
            return nil
        }

        // A bare root is the default anyway; nothing worth storing.
        guard path != "/" else { return nil }
        return path
    }
}
