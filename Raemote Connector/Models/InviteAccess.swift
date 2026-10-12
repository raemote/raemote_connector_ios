import Foundation

/// A device's access scope, as reported by `GET /_hub/info`'s `access` field.
///
/// Mirrors the server's `scope_json` shape: `{"all":true}` or
/// `{"all":false,"ports":[…]}`. A server that predates per-device scopes
/// omits the field entirely, which decodes to `nil` at the call site — the
/// invite flow then treats it as "cannot restrict" and falls back to the
/// classic inherit-everything invitation.
enum DeviceAccess: Codable, Equatable, Sendable {
    /// Every app on the server, now and later.
    case all
    /// Only apps whose origin port is in this set. An empty set grants
    /// nothing (the server treats a malformed scope line the same way).
    case ports(Set<UInt16>)

    private enum CodingKeys: String, CodingKey {
        case all
        case ports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if (try container.decodeIfPresent(Bool.self, forKey: .all)) == true {
            self = .all
            return
        }
        // `all == false`: the port list is the grant. A missing or malformed
        // `ports` fails closed to the empty set instead of erroring — an
        // unreadable scope must never read as "everything".
        let ports = (try container.decodeIfPresent([UInt16].self, forKey: .ports)) ?? []
        self = .ports(Set(ports))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(true, forKey: .all)
        case .ports(let ports):
            try container.encode(false, forKey: .all)
            try container.encode(Array(ports).sorted(), forKey: .ports)
        }
    }

    /// Human-readable one-liner for captions: `all apps` / `ports 3000, 8080`.
    var caption: String {
        switch self {
        case .all:
            return "all apps"
        case .ports(let ports):
            if ports.isEmpty { return "no apps" }
            return "ports " + ports.sorted().map(String.init).joined(separator: ", ")
        }
    }
}

/// Pure logic behind the invite-access picker: which ports a selection really
/// grants, and whether offering the picker at all makes sense.
///
/// Free of SwiftUI and iroh so it unit-tests cleanly, and it documents the
/// one honest caveat of the permission system: the server's allowlist is per
/// **origin port**, never per app — two apps on the same port travel together.
enum InviteAccess {
    /// The body for a *restricted* invitation (`POST /_hub/invite`), sorted
    /// for a deterministic encoding. "Inherit this device's access" is a
    /// bodyless request — the absence of a body *is* the inherit signal, so
    /// this only ever encodes a real list.
    nonisolated static func requestBody(ports: [UInt16]) throws -> Data {
        struct Body: Encodable { let ports: [UInt16] }
        return try JSONEncoder().encode(Body(ports: ports.sorted()))
    }

    /// The ports granted by checking `selected` (app names): the sorted union
    /// of the checked apps' ports, skipping any port that isn't a valid `u16`.
    nonisolated static func grantedPorts(apps: [AppInfo], selected: Set<String>) -> [UInt16] {
        var ports = Set<UInt16>()
        for app in apps where selected.contains(app.name) {
            if let port = UInt16(exactly: app.port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    /// The *unchecked* apps that are reached anyway because they share a
    /// granted port. Shown in the picker so the list never implies app-level
    /// granularity the server doesn't have.
    nonisolated static func alsoGrantedApps(apps: [AppInfo], selected: Set<String>) -> [AppInfo] {
        let granted = Set(grantedPorts(apps: apps, selected: selected))
        return apps.filter { app in
            !selected.contains(app.name)
                && UInt16(exactly: app.port).map(granted.contains) ?? false
        }
    }

    /// The apps this device may actually offer: everything when the scope is
    /// `all` (or unreported), and only apps on allowed ports when the server
    /// reported a port list — a stale catalog can't offer what the device
    /// itself may not grant.
    nonisolated static func selectableApps(access: DeviceAccess?, apps: [AppInfo]) -> [AppInfo] {
        guard case .some(.ports(let ports)) = access else { return apps }
        return apps.filter { app in
            UInt16(exactly: app.port).map(ports.contains) ?? false
        }
    }

    /// Whether the access picker is worth showing.
    ///
    /// It isn't when there is no real choice: an older server that doesn't
    /// report `access` (so a "limited" invite would be silently ignored),
    /// no apps to pick from, or a scope of at most one port — where "same as
    /// this device" and "only selected apps" grant exactly the same thing.
    nonisolated static func shouldOfferChoice(access: DeviceAccess?, apps: [AppInfo]) -> Bool {
        guard let access else { return false }
        guard !selectableApps(access: access, apps: apps).isEmpty else { return false }
        if case .ports(let ports) = access, ports.count <= 1 { return false }
        return true
    }

    /// Friendly text for a failed mint. The server's `400 beyond_grant`
    /// means the selection exceeds this device's own access (usually a
    /// catalog that went stale after a scope change), which the raw error
    /// code would not tell a user.
    nonisolated static func mintErrorMessage(_ error: Error) -> String {
        if let irohError = error as? IrohError,
           case .httpError(let code, let message) = irohError,
           code == 400,
           message.contains("beyond_grant") {
            return "The server refused this selection: it grants more than this device has. Tap Refresh Apps to reload the list, then try again."
        }
        return error.localizedDescription
    }
}
