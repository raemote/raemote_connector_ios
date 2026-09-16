import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Wraps the system share sheet (`UIActivityViewController`).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Vends a web page to the share sheet the way Safari does: a placeholder
/// Raemote link for link-sharing activities, and a PDF for print/markup/save.
final class WebPageActivityItemSource: NSObject, UIActivityItemSource {
    private let link: URL
    private let pdfProvider: () -> URL?

    init(link: URL, pdfProvider: @escaping () -> URL?) {
        self.link = link
        self.pdfProvider = pdfProvider
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        link
    }

    func activityViewController(
        _: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        switch activityType {
        case .print, .markupAsPDF:
            return pdfProvider() ?? link
        default:
            return link
        }
    }

    func activityViewController(
        _: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        switch activityType {
        case .print, .markupAsPDF:
            return UTType.pdf.identifier
        default:
            return UTType.url.identifier
        }
    }
}
