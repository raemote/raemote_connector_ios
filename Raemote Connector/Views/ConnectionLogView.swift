import SwiftUI

/// The hidden connection-diagnosis modal: a live view of `ConnectionLog` for
/// one server (plus endpoint-wide events), newest first.
///
/// Opened by long-pressing the Connection row in `ServerDetailView` — there is
/// no visible affordance. Entries stream in while the sheet is up, so it can
/// be watched while reproducing a connection problem.
struct ConnectionLogView: View {
    /// The server whose events are shown (endpoint-wide entries come too).
    let nodeId: String
    /// The server's display name (sheet header).
    let title: String
    /// Read live for the header's status line.
    let monitor: IrohConnectionMonitor

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// Newest first — a live tail, no scrolling needed to watch incoming events.
    private var rows: [ConnectionLog.Entry] {
        ConnectionLog.shared.entries(for: nodeId).reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow
                }
                if rows.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Connection Events",
                            systemImage: "waveform.path.ecg",
                            description: Text("Events appear here as this app connects to the server. Reopen by long-pressing the Connection row.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Events") {
                        ForEach(rows) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .navigationTitle("Connection Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = ConnectionLog.shared.exportText(for: nodeId)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        ConnectionLog.shared.clear()
                    }
                }
            }
        }
    }

    /// Which server this is, and its live connection status — so the log and
    /// the indicator it explains are visible side by side.
    private var infoRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch monitor.state(for: nodeId) {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .red
        case .unknown: .gray
        }
    }

    private var statusText: String {
        switch monitor.state(for: nodeId) {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .unknown: "Checking…"
        }
    }

    private func entryRow(_ entry: ConnectionLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                // Endpoint-wide events belong to no single server — say so.
                if entry.nodeId == nil {
                    Text("all servers")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}
