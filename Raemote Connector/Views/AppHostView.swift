import SwiftUI

/// The single presented-app screen.
///
/// The app on screen is `sessionManager.activeKey` — **not** the navigation
/// route. Switching apps therefore only changes `activeKey`, so the stack never
/// churns and the presented `WKWebView` is always the one belonging to the
/// active session (`AppWebView` is `.id`-ed by the key).
///
/// The floating control's expansion lives here, above that identity change, so
/// it is one value used for both the card's morph and its hit-testing, and it
/// survives switching apps.
struct AppHostView: View {
    let sessionManager: WebAppSessionManager
    let irohService: IrohService
    let monitor: IrohConnectionMonitor
    /// Another running app was tapped in the strip. The router (the root list)
    /// owns the navigation stack, so it decides how to switch.
    let onSwitchSession: (WebAppSessionKey) -> Void
    /// A refreshed catalog from the in-app strip's refresh button, so the root
    /// list can update that server's app list.
    let onAppsUpdated: (String, [AppInfo]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isControlExpanded = false

    var body: some View {
        Group {
            if let key = sessionManager.activeKey,
               sessionManager.session(for: key) != nil {
                AppWebView(
                    key: key,
                    irohService: irohService,
                    monitor: monitor,
                    sessionManager: sessionManager,
                    isControlExpanded: $isControlExpanded,
                    onSwitchSession: onSwitchSession,
                    onAppsUpdated: onAppsUpdated
                )
                // One identity per session: the correct session's web view is
                // attached (makeUIView runs), and per-session setup restarts.
                .id(key)
            } else {
                // The presented app is gone — closed from a list, its server
                // removed, or its session dropped. Leave instead of resurrecting
                // it (the view no longer opens sessions itself).
                Color.clear
                    .onAppear { dismiss() }
            }
        }
    }
}
