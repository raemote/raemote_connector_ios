import Combine
import SwiftUI
import UIKit

/// The invite sheet: a paired device shows this so another device can pair.
struct InviteDeviceView: View {
    /// The server this invitation is for (display name).
    let serverName: String
    /// The one-time `raemote://bind?...` link.
    let uri: String
    /// When the invitation expires.
    let expiresAt: Date

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Have the other device open Raemote, tap +, and scan this code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let image = QRCodeImage.make(from: uri) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Invitation QR code")
                    }

                    Text(expiryText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(expired ? .red : .secondary)

                    Text(uri)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = uri
                        } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showShare = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(expired)

                    Text("This link pairs one device and can only be used once.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Invite Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ActivityView(items: shareItems)
            }
            .onReceive(ticker) { now = $0 }
        }
    }

    private var expired: Bool {
        expiresAt.timeIntervalSince(now) <= 0
    }

    private var expiryText: String {
        let remaining = Int(expiresAt.timeIntervalSince(now))
        guard remaining > 0 else { return "This invitation has expired." }
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }

    private var shareItems: [Any] {
        [serverName.isEmpty ? "Raemote invitation" : "Raemote invitation for \(serverName)", uri]
    }
}

#Preview {
    InviteDeviceView(
        serverName: "Studio Mac mini",
        uri: "raemote://bind?node=abc&token=def&exp=9999999999",
        expiresAt: Date().addingTimeInterval(300)
    )
}
