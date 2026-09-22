import Foundation

/// Remembers the page title each app showed when the user opened it, so the app
/// list can use a name the user recognizes instead of a fallback like the
/// process name ("node", "python").
///
/// The server names discovered apps from the HTML `<title>` of `GET /`, which
/// many apps only set from JavaScript after they boot (and an auth-gated app
/// answers with no page at all). The `WKWebView` sees the *live* title, so the
/// first meaningful one of each visit is cached here.
///
/// Names are keyed by **server node id + app name**, matching `ProxyPortStore`:
/// two servers that both run an app called e.g. `jellyfin` must never share a
/// cached name.
enum AppNameStore {
    private static let storageKey = "appNamesByApp"
    /// Schema version of the stored names. Bumped when an older build could
    /// have stored a bad value; a store written before the current version is
    /// dropped once (see `migrateIfNeeded`).
    private static let versionKey = "appNamesSchemaVersion"
    /// v1 → v2: builds before the error-page marker could store the title of our
    /// own error page ("Couldn't reach the app.") as an app's name.
    private static let currentVersion = 2

    private static func entryKey(nodeId: String, app: String) -> String {
        "\(nodeId)/\(app)"
    }

    /// Drop names an older build may have stored incorrectly.
    ///
    /// Names are cheap to re-learn from the app's live title on its next visit,
    /// so a one-time reset is cleaner than trying to guess which stored values
    /// were bad (which would mean matching error-page text).
    private static func migrateIfNeeded(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        defaults.removeObject(forKey: storageKey)
        defaults.set(currentVersion, forKey: versionKey)
    }

    /// The cached display name for an app, if any.
    ///
    /// Validated on read as well as on write, so a value that would be rejected
    /// today is never surfaced.
    static func name(
        nodeId: String,
        app: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        migrateIfNeeded(defaults)
        let map = defaults.dictionary(forKey: storageKey) as? [String: String]
        guard let stored = map?[entryKey(nodeId: nodeId, app: app)] else { return nil }
        return normalized(stored)
    }

    /// Every cached name for one server, keyed by app name.
    static func names(
        nodeId: String,
        defaults: UserDefaults = .standard
    ) -> [String: String] {
        migrateIfNeeded(defaults)
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

    /// Store `rawTitle` as the app's display name, unless it is a placeholder
    /// (`""`, "Loading…", "127.0.0.1:52001", …). Returns the stored name, or
    /// `nil` when the title was not usable.
    @discardableResult
    static func remember(
        _ rawTitle: String,
        nodeId: String,
        app: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        migrateIfNeeded(defaults)
        guard let name = normalized(rawTitle) else { return nil }
        var map = (defaults.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
        guard map[entryKey(nodeId: nodeId, app: app)] != name else { return name }
        map[entryKey(nodeId: nodeId, app: app)] = name
        defaults.set(map, forKey: storageKey)
        return name
    }

    /// Collapse whitespace and reject titles that would make a worse name than
    /// the server already has.
    static func normalized(_ rawTitle: String) -> String? {
        let collapsed = rawTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= 120 else { return nil }

        let lower = collapsed.lowercased()
        let placeholders: Set<String> = [
            "loading", "loading...", "loading…", "untitled", "new tab", "about:blank",
        ]
        if placeholders.contains(lower) { return nil }
        // The loopback proxy origin — never a real app name.
        if lower.contains("127.0.0.1") || lower.contains("localhost") { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return nil }
        // A bare "host:port", port number, or IP address.
        if collapsed.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }) { return nil }
        return collapsed
    }
}
