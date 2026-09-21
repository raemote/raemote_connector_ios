import SwiftUI

/// An app's icon: the cached favicon when available, else a monogram (the
/// app's initial on a stable tint).
///
/// Loading is lazy — a row starts the fetch only when it appears, and
/// `AppIconStore` de-duplicates concurrent loads of the same app. The icon's
/// location comes from the catalog registered with the store, so callers only
/// need the server's node id and the app name.
struct AppIconView: View {
    let nodeId: String
    let app: String
    let service: IrohService
    var size: CGFloat = 28

    @State private var image: UIImage?

    private var cornerRadius: CGFloat { size * 0.24 }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: taskID) {
            image = AppIconStore.shared.cached(nodeId: nodeId, app: app)
            guard image == nil else { return }
            image = await AppIconStore.shared.icon(nodeId: nodeId, app: app) { path in
                try await service.fetchIcon(nodeId: nodeId, app: app, path: path)
            }
        }
    }

    /// Identity for `.task`: the app plus where its icon lives. When a catalog
    /// refresh supplies an icon path (or the app's port changes), this changes
    /// and the icon is refetched — otherwise a failed first attempt would stick
    /// for the lifetime of the row.
    private var taskID: String {
        "\(nodeId)/\(app)/\(AppIconStore.shared.descriptorID(nodeId: nodeId, app: app))"
    }

    /// The fallback when there is no usable favicon: the app's first letter on
    /// a stable colour, so rows stay scannable instead of showing a generic
    /// placeholder.
    private var monogram: some View {
        ZStack {
            Rectangle().fill(tint.gradient)
            Text(initial)
                .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        let first = app.first { $0.isLetter || $0.isNumber }
        return String(first ?? "?").uppercased()
    }

    /// A deterministic hash (not `hashValue`, which is seeded per launch), so
    /// an app keeps the same colour across relaunches.
    private var tint: Color {
        let palette: [Color] = [.blue, .indigo, .teal, .green, .orange, .pink, .purple, .brown]
        var hash = 5381
        for byte in app.utf8 { hash = (hash &* 33) &+ Int(byte) }
        let index = Int(UInt(bitPattern: hash) % UInt(palette.count))
        return palette[index]
    }
}
