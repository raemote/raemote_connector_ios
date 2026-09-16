import Foundation

struct AppInfo: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let port: Int

    init(name: String, path: String, port: Int) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.port = port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        port = try container.decode(Int.self, forKey: .port)
    }
}
