import Foundation

struct Server: Identifiable, Codable, Hashable {
    let id: UUID
    let nodeId: String
    /// A user-chosen alias. Empty means "use the server's own name".
    var name: String
    /// The name the server reports (from `/_hub/info`), when known.
    var reportedName: String?
    var apps: [AppInfo]

    init(
        nodeId: String,
        name: String = "",
        reportedName: String? = nil,
        apps: [AppInfo] = []
    ) {
        self.id = UUID()
        self.nodeId = nodeId
        self.name = name
        self.reportedName = reportedName
        self.apps = apps
    }

    /// What to show for this server: alias, else the reported name, else a
    /// short form of the node id.
    var displayName: String {
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty { return alias }
        if let reported = reportedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reported.isEmpty {
            return reported
        }
        return "Server \(nodeId.prefix(8))"
    }
}
