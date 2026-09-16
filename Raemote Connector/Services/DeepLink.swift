import Foundation

/// A parsed `raemote://open?node=…&app=…&path=…` deep link.
///
/// The `raemote` scheme is registered in `Info.plist` (`CFBundleURLTypes`), so
/// iOS launches this app for a matching URL; `ContentView` handles it via
/// `.onOpenURL`.
///
/// - Note: the scheme and its parameters are still a placeholder (produced by
///   `WebShare.raemoteURL`); the exact shape may change.
struct DeepLink: Equatable {
    /// The server (node id) the link points at.
    let nodeId: String?
    /// The catalog app name within that server.
    let appName: String?
    /// A path within the app.
    let path: String?

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
