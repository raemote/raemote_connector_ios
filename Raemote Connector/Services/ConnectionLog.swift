import Foundation
import Observation

/// In-memory, per-launch capture of connection events, surfaced by the hidden
/// diagnosis modal (long-press the Connection row on a server's detail
/// screen).
///
/// Every entry is tagged with the server it describes (`nodeId`), or `nil` for
/// endpoint-wide events (no single server — an endpoint rebuild, a teardown).
/// A modal for server A shows A's entries plus the global ones and never
/// another server's (the NodeId-isolation rule).
///
/// The buffer is a ring: at most `capacity` entries are kept and the oldest
/// fall off, so a chatty failure loop can't grow memory. Nothing is written to
/// disk — a relaunch starts empty — and each append also `print`s, so the
/// Xcode console keeps working alongside the modal.
@MainActor
@Observable
final class ConnectionLog {
    /// One captured event.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let date: Date
        /// The server this event belongs to, or `nil` for endpoint-wide ones.
        let nodeId: String?
        let message: String

        init(date: Date = .now, nodeId: String?, message: String) {
            self.id = UUID()
            self.date = date
            self.nodeId = nodeId
            self.message = message
        }
    }

    /// The app-wide buffer the service and monitor write to.
    static let shared = ConnectionLog()

    /// Default ring capacity — enough for several minutes of a failing
    /// connection loop, which is all a diagnosis session needs.
    static let defaultCapacity = 500

    /// Entries in append (chronological) order.
    private(set) var entries: [Entry] = []

    let capacity: Int

    init(capacity: Int? = nil) {
        // `nil` in the default argument: default args evaluate outside the
        // main actor, where the actor-isolated `defaultCapacity` is unusable.
        self.capacity = max(1, capacity ?? Self.defaultCapacity)
    }

    /// Capture `message` (also printed to the console). `nodeId` scopes the
    /// entry to one server; omit it for endpoint-wide events.
    func append(_ message: String, nodeId: String? = nil) {
        entries.append(Entry(nodeId: nodeId, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        let scope = nodeId.map { String($0.prefix(8)) } ?? "endpoint"
        print("[ConnectionLog] [\(scope)] \(message)")
    }

    /// This server's entries plus the endpoint-wide ones, chronological
    /// (the UI reverses for newest-first display).
    func entries(for nodeId: String) -> [Entry] {
        entries.filter { $0.nodeId == nil || $0.nodeId == nodeId }
    }

    /// A copyable, shareable rendering of `entries(for:)` — one line per event.
    func exportText(for nodeId: String) -> String {
        entries(for: nodeId).map { entry in
            let scope = entry.nodeId.map { String($0.prefix(8)) } ?? "all"
            let stamp = entry.date.formatted(
                .dateTime
                    .year().month().day()
                    .hour().minute().second()
                    .secondFraction(.fractional(3))
            )
            return "\(stamp) [\(scope)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    /// Empty the buffer (the modal's Clear button).
    func clear() {
        entries.removeAll()
    }
}
