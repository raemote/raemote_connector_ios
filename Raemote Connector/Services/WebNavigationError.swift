import Foundation

/// Classifies `WKNavigation` failures that are normal by-products of what we
/// asked for, rather than page-load errors worth showing the user.
nonisolated enum WebNavigationError {
    /// Whether `error` should be silently ignored.
    ///
    /// Two cases are routine:
    /// - turning a link into a `WKDownload` (an attachment, or a type WebKit
    ///   can't display) interrupts the frame load on purpose — WebKit reports
    ///   `WebKitErrorDomain` code 102, "frame load interrupted";
    /// - the load was cancelled, e.g. because we navigated or downloaded instead.
    static func isBenign(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return true
        }
        guard error.code == frameLoadInterruptedByPolicyChange else { return false }
        // Historically `WebKitErrorDomain`; newer SDKs expose `WKErrorDomain`.
        return error.domain == "WebKitErrorDomain" || error.domain == "WKErrorDomain"
    }

    /// `WebKitErrorFrameLoadInterruptedByPolicyChange` (legacy WebKit code).
    private static let frameLoadInterruptedByPolicyChange = 102
}
