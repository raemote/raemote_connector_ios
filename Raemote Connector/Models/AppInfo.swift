import Foundation

struct AppInfo: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let port: Int
    /// Same-origin path of the app's declared icon (e.g. `/favicon.ico`), when
    /// the server's discovery probe found one. `nil` for manual apps and older
    /// servers; the client then falls back to `/favicon.ico`.
    let icon: String?

    init(name: String, path: String, port: Int, icon: String? = nil) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.port = port
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        port = try container.decode(Int.self, forKey: .port)
        // Optional: an older server omits it, and a stored `Server` predates it.
        icon = try? container.decode(String.self, forKey: .icon)
    }
}
