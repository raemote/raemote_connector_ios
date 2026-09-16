import Foundation
import UniformTypeIdentifiers

/// How the current web view content should be shared.
enum WebShareContent: Equatable {
    /// A rendered web page: share a link (placeholder deep link) plus a PDF for
    /// print / markup / save.
    case webPage
    /// A concrete file (PDF, video, image, markdown, ...): share the file itself
    /// so the sheet reflects the apps installed on the device.
    case file
}

/// Pure helpers for deciding what the share sheet should receive. Kept free of
/// UIKit/WebKit so they can be unit-tested.
enum WebShare {
    /// Classify by the main-frame response MIME type. HTML (or unknown) is a page.
    static func contentKind(mimeType: String?) -> WebShareContent {
        guard let mime = mimeType?.lowercased(), !mime.isEmpty else { return .webPage }
        if mime.hasPrefix("text/html") || mime.hasPrefix("application/xhtml") {
            return .webPage
        }
        return .file
    }

    /// A filename extension for a MIME type, when the system knows one.
    static func filenameExtension(forMimeType mimeType: String?) -> String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        return UTType(mimeType: mimeType)?.preferredFilenameExtension
    }

    /// A safe file-name component: letters, digits, `-`, `_`, `.` and spaces
    /// (spaces become `-`); everything else becomes `-`.
    static func sanitize(_ name: String) -> String {
        let mapped = name.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." || ch == " " {
                return ch
            }
            return "-"
        }
        let collapsed = String(mapped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return collapsed.isEmpty ? "download" : String(collapsed.prefix(64))
    }

    /// File name for the PDF snapshot of a page.
    static func pageFilename(title: String?, appName: String) -> String {
        let base = sanitize((title?.isEmpty == false ? title! : appName))
        return "\(base).pdf"
    }

    /// File name for a fetched file: keep the URL's extension when present,
    /// otherwise derive one from the MIME type.
    static func fileFilename(url: URL, appName: String, mimeType: String?) -> String {
        let last = url.lastPathComponent
        let hasName = !last.isEmpty && last != "/"
        let stem: String
        let ext: String
        if hasName {
            stem = sanitize((last as NSString).deletingPathExtension)
            let urlExt = (last as NSString).pathExtension
            ext = urlExt.isEmpty ? (filenameExtension(forMimeType: mimeType) ?? "") : urlExt
        } else {
            stem = sanitize(appName)
            ext = filenameExtension(forMimeType: mimeType) ?? ""
        }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// The (placeholder) deep link used to share a Raemote page.
    ///
    /// - Important: The `raemote://open` handler is **not implemented yet**; this
    ///   is a placeholder so link-sharing works. The real scheme/shape is TBD.
    static func raemoteURL(nodeId: String, appName: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "raemote"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "node", value: nodeId),
            URLQueryItem(name: "app", value: appName),
            URLQueryItem(name: "path", value: path.isEmpty ? "/" : path),
        ]
        return components.url ?? URL(string: "raemote://open")!
    }

    /// Write `data` to a unique file in the temporary directory under `filename`.
    static func writeTemporaryFile(_ data: Data, filename: String) throws -> URL {
        let url = try shareDirectory().appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        return url
    }

    /// Move an already-downloaded temporary file into our share directory under
    /// `filename` (so it keeps a stable name while the sheet is open).
    static func placeTemporaryFile(at source: URL, filename: String) throws -> URL {
        let url = try shareDirectory().appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: source, to: url)
        return url
    }

    /// A directory for files handed to the share sheet.
    static func shareDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raemote-share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
