import SwiftUI
import UIKit

/// The "Server Info…" sheet: the handful of facts about a server that aren't
/// part of day-to-day use — above all the full **node id**, which is needed
/// for bug reports and when re-pairing a device, and nowhere else. It lives
/// here so the main screens never show it: users should not have to care
/// about cryptographic identities to open Jellyfin.
struct ServerInfoView: View {
    let title: String
    let nodeId: String
    let appCount: Int

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Name", value: title)
                    LabeledContent("Apps", value: "\(appCount)")
                }

                Section {
                    Text(nodeId)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = nodeId
                        copied = true
                    } label: {
                        Label(
                            copied ? "Copied" : "Copy Node ID",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                } header: {
                    Text("Node ID")
                } footer: {
                    Text("This server's cryptographic identity. You never type it — it's useful in bug reports and when re-pairing.")
                }
            }
            .navigationTitle("Server Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ServerInfoView(title: "Mac mini", nodeId: "abcdef0123456789abcdef0123456789abcdef01", appCount: 4)
}
