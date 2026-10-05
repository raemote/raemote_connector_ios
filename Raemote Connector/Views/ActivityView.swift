import SwiftUI
import UIKit

/// A thin `UIActivityViewController` wrapper for presenting the system share
/// sheet from SwiftUI (e.g. sharing an invite link).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
