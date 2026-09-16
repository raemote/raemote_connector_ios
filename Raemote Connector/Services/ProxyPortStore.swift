import Foundation

/// Remembers the loopback port used for each web app so its `WKWebView` origin
/// (`http://127.0.0.1:<port>`) stays stable across launches.
///
/// Site data — cookies, `localStorage`, IndexedDB, service workers — is scoped
/// to the origin **including the port**, so a fresh ephemeral port every run
/// would silently reset the app (logins, settings, …) every time. Reusing the
/// same port keeps the origin stable, and giving each app its own port keeps
/// them isolated from one another.
///
/// Ports are keyed by **server node id + app name**: two different servers that
/// both run an app called e.g. `jellyfin` must never share a loopback origin,
/// or they would share cookies/localStorage.
enum ProxyPortStore {
    private static let storageKey = "proxyPortsByApp"

    private static func entryKey(nodeId: String, app: String) -> String {
        "\(nodeId)/\(app)"
    }

    static func preferredPort(
        nodeId: String,
        app: String,
        defaults: UserDefaults = .standard
    ) -> UInt16? {
        guard let map = defaults.dictionary(forKey: storageKey) as? [String: Int],
              let value = map[entryKey(nodeId: nodeId, app: app)]
        else { return nil }
        return UInt16(exactly: value)
    }

    static func remember(
        _ port: UInt16,
        nodeId: String,
        app: String,
        defaults: UserDefaults = .standard
    ) {
        var map = (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
        let entry = entryKey(nodeId: nodeId, app: app)
        guard map[entry] != Int(port) else { return }
        map[entry] = Int(port)
        defaults.set(map, forKey: storageKey)
    }
}
