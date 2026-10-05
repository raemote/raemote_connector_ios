import Foundation

/// A parsed `raemote://open?node=…&app=…&path=…` deep link.
///
/// The `raemote` scheme is registered in `Info.plist` (`CFBundleURLTypes`), so
/// iOS launches this app for a matching URL; `ContentView` handles it via
/// `.onOpenURL`.
struct DeepLink: Equatable {
    /// The server (node id) the link points at.
    let nodeId: String?
    /// The catalog app name within that server.
    let appName: String?
    /// A path within the app.
    let path: String?

    /// Build the canonical `raemote://open` URL this parser accepts (kept in
    /// one place so the produced shape and the round-trip test can't drift).
    static func openURL(nodeId: String, appName: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "raemote"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "node", value: nodeId),
            URLQueryItem(name: "app", value: appName),
            URLQueryItem(name: "path", value: path.isEmpty ? "/" : path),
        ]
        return components.url ?? URL(string: "raemote://open")!
    }

    /// Parse a `raemote://` URL; returns `nil` for unrelated or empty URLs.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "raemote" else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty else {
                return nil
            }
            return raw
        }

        let node = value("node")
        let app = value("app")
        // Require at least one meaningful parameter.
        guard node != nil || app != nil else { return nil }

        nodeId = node
        appName = app
        path = value("path")
    }
}
