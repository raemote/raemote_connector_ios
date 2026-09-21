import Observation
import SwiftUI
import UIKit
import WebKit

/// A share-sheet request. `Identifiable` so it can drive `.sheet(item:)`.
struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Observable navigation state shared between `AppWebView` and the underlying
/// `WKWebView`. SwiftUI can't observe `WKWebView` directly, so the coordinator
/// mirrors its history flags here and the buttons drive it back.
@MainActor
@Observable
final class WebViewState {
    var isLoading = true
    var errorMessage: String?
    var canGoBack = false
    var canGoForward = false
    /// The web view is in true (element) fullscreen; hide the control then.
    var isFullscreen = false
    var isPreparingShare = false
    /// The file currently downloading from the page, if any. Shown in the busy
    /// banner so a download in flight is never invisible.
    var downloadingFileName: String?
    /// How many downloads are running (several can overlap); not observed.
    @ObservationIgnored var activeDownloadCount = 0
    var shareRequest: ShareRequest?
    var shareError: String?

    /// Main-frame URL and MIME type, mirrored from the navigation delegate.
    var currentURL: URL?
    var currentMimeType: String?

    @ObservationIgnored weak var webView: WKWebView?

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func downloadStarted(named name: String) {
        activeDownloadCount += 1
        downloadingFileName = name
    }

    func downloadFinished() {
        activeDownloadCount = max(0, activeDownloadCount - 1)
        if activeDownloadCount == 0 { downloadingFileName = nil }
    }
}

struct AppWebView: View {
    /// Which app this view presents. The session, launch path, port and learned
    /// name are all derived from this one key (the NodeId-isolation rule).
    let key: WebAppSessionKey
    let irohService: IrohService
    let monitor: IrohConnectionMonitor
    /// The running-apps registry: this view presents one session; leaving does
    /// not close it (apps run in the background until the user closes them).
    let sessionManager: WebAppSessionManager
    /// Whether the floating control is expanded. Owned by `AppHostView` so it
    /// survives switching apps and is the *single* value behind both the card's
    /// morph and its hit-testing.
    @Binding var isControlExpanded: Bool
    /// The user tapped another running app in the strip; the router decides how
    /// to switch (the current session stays warm).
    var onSwitchSession: (WebAppSessionKey) -> Void = { _ in }
    /// A refreshed catalog for this server, so the root list can update its app
    /// lists (and the icon store its descriptors).
    var onAppsUpdated: (String, [AppInfo]) -> Void = { _, _ in }

    private var nodeId: String { key.nodeId }
    private var appName: String { key.app }
    /// An optional path/query to open the app with (`AppLaunchStore`), for apps
    /// whose entry URL carries a one-time token. Applies on the first proxy
    /// start; later activations resume where the page already is.
    private var launchPath: String? { AppLaunchStore.path(nodeId: key.nodeId, app: key.app) }
    /// The app's catalog port (display only; `0` when unknown).
    private var port: Int { AppIconStore.shared.port(nodeId: key.nodeId, app: key.app) }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    /// Where the floating control sits (persisted across launches).
    @State private var placement = FloatingControlStore.load()
    /// Live drag offset while the user moves the circle.
    @State private var dragTranslation: CGSize = .zero
    /// How far the card has morphed out of the circle: 0 = collapsed onto the
    /// circle, 1 = at its resting place. Interpolating it is what makes the card
    /// grow out of the button. Kept in sync with `isControlExpanded`.
    @State private var expansion: CGFloat = 0
    /// A strip refresh (server discovery scan) is in flight.
    @State private var isRefreshingCatalog = false

    private let controlDiameter: CGFloat = 52

    init(
        key: WebAppSessionKey,
        irohService: IrohService,
        monitor: IrohConnectionMonitor,
        sessionManager: WebAppSessionManager,
        isControlExpanded: Binding<Bool>,
        onSwitchSession: @escaping (WebAppSessionKey) -> Void = { _ in },
        onAppsUpdated: @escaping (String, [AppInfo]) -> Void = { _, _ in }
    ) {
        self.key = key
        self.irohService = irohService
        self.monitor = monitor
        self.sessionManager = sessionManager
        self._isControlExpanded = isControlExpanded
        self.onSwitchSession = onSwitchSession
        self.onAppsUpdated = onAppsUpdated
        // Seed the morph so a session swap (which recreates this view) starts
        // already expanded when the shared value is expanded — no flash.
        self._expansion = State(initialValue: isControlExpanded.wrappedValue ? 1 : 0)
    }

    /// What to call this app: the page title learned from the web view (persisted
    /// per server + app), else the server's name for it.
    private var displayName: String {
        AppNameStore.name(nodeId: key.nodeId, app: key.app) ?? key.app
    }

    /// What the page is busy doing, if anything.
    private func busyText(session: WebAppSession) -> String? {
        let state = session.state
        if let name = state.downloadingFileName { return "Downloading \(name)…" }
        if state.isPreparingShare { return "Preparing to share…" }
        return nil
    }

    /// A small banner across the top of the page, so a download or a share that
    /// takes time is visible while the floating card is collapsed.
    private func busyBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(Capsule())
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    var body: some View {
        // The router creates the session before pushing this view, and
        // `AppHostView` only presents an existing session.
        if let session = sessionManager.session(for: key) {
            present(session)
        } else {
            Color.clear
        }
    }

    /// The presented session: full-screen page + floating control.
    private func present(_ session: WebAppSession) -> some View {
        @Bindable var session = session
        let state = session.state
        @Bindable var webState = session.state
        return GeometryReader { geometry in
            ZStack {
                if let proxyURL = session.proxyURL {
                    // Respect the safe area, like Safari: the page is laid out
                    // clear of the status bar/notch and the home indicator
                    // instead of running underneath them.
                    WebViewRepresentable(
                        url: proxyURL,
                        session: session,
                        appName: appName
                    )

                    if state.isLoading {
                        ProgressView("Loading \(displayName)...")
                    }

                    if let errorMessage = state.errorMessage {
                        ContentUnavailableView(
                            "Failed to Load",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                    }
                } else {
                    // The web view isn't started until the serve connection is
                    // up, so the user waits here (with a spinner) instead of
                    // hitting a failing proxy.
                    connectionGate
                }

                if session.proxyURL != nil, !state.isFullscreen {
                    floatingControl(in: geometry.size, session: session)
                }

                // Any operation that takes time announces itself here: the
                // floating card collapses when it starts one, so its own
                // spinner would be hidden.
                if let busy = busyText(session: session) {
                    busyBanner(busy)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: busyText(session: session))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // Paint the safe-area bands (notch, home indicator) the same colour the
        // web view uses for overscroll, so they read as deliberate.
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        // Re-enable the edge swipe-to-go-back, which SwiftUI turns off when the
        // navigation bar is hidden.
        .background(InteractivePopGestureEnabler())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            // Mark this session active (strip, status, LRU ordering), even on
            // re-appearance — the proxy may already be running.
            sessionManager.activate(key)
            await connectThenStart(session: session)
            // Keep the direct/relayed indicator current while presented.
            await pollConnectionKind(session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await revalidate(session: session) }
        }
        .onChange(of: monitor.state) { _, newState in
            if case .connected = newState, session.proxyURL == nil {
                Task { await startProxyIfConnected(session: session) }
            }
        }
        .onChange(of: isControlExpanded) { _, expanded in
            withAnimation(.snappy(duration: 0.3)) { expansion = expanded ? 1 : 0 }
        }
        // No teardown on disappear: background sessions keep their proxy and
        // page. Stopping an app is only possible from the Running list.
        .sheet(item: $webState.shareRequest) { request in
            ActivityView(items: request.items)
        }
        .alert("Couldn't Share", isPresented: .constant(webState.shareError != nil)) {
            Button("OK") { webState.shareError = nil }
        } message: {
            if let shareError = webState.shareError {
                Text(shareError)
            }
        }
    }

    // MARK: - Connection gate

    @ViewBuilder
    private var connectionGate: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to server…")
                .font(.headline)
            if case .disconnected(let reason) = monitor.state,
               let reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    /// Wait for a live connection, then bring up the loopback proxy. Retries
    /// until connected (or the view goes away). Re-presenting a running app
    /// skips the wait: the proxy is already up.
    private func connectThenStart(session: WebAppSession) async {
        if session.proxyURL != nil {
            await irohService.validateConnection(nodeId: nodeId)
            return
        }
        while !Task.isCancelled {
            await irohService.validateConnection(nodeId: nodeId)
            if case .connected = monitor.state { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        await startProxyIfConnected(session: session)
    }

    /// Sample the transport (direct vs relayed) until the view goes away. A
    /// sample rather than a subscription: the FFI's `watchPaths` needs a tokio
    /// runtime context a Swift caller can't provide (see `refreshPathKind`).
    private func pollConnectionKind(session: WebAppSession) async {
        while !Task.isCancelled {
            // Only the presented session drives the transport indicator;
            // background sessions don't need live sampling.
            if sessionManager.isActive(key) {
                await irohService.refreshPathKind(nodeId: nodeId)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func startProxyIfConnected(session: WebAppSession) async {
        guard session.proxyURL == nil else { return }
        guard case .connected = monitor.state else { return }
        do {
            // A stored launch path (e.g. `/?token=…`) applies on first start;
            // later activations resume where the page already is.
            _ = try await sessionManager.ensureProxy(for: session, launchPath: launchPath)
        } catch {
            session.state.errorMessage = error.localizedDescription
        }
    }

    /// On foreground, make sure the serve connection is alive and retry a page
    /// that failed while the app was suspended.
    private func revalidate(session: WebAppSession) async {
        guard sessionManager.isActive(key) else { return }
        await irohService.validateConnection(nodeId: nodeId)
        let state = session.state
        if state.errorMessage != nil, let url = session.proxyURL {
            state.errorMessage = nil
            state.isLoading = true
            state.webView?.load(URLRequest(url: url))
        }
    }

    // MARK: - Floating control

    private var controlCardWidth: CGFloat { 268 }
    private var controlHeaderHeight: CGFloat { 50 }
    private var controlButtonsHeight: CGFloat { 54 }
    /// The running-apps strip's height: one row of app icons, each in a square
    /// tap target this tall. The strip's own frame and the card's height math
    /// both use this value, so the content can never outgrow the space reserved
    /// for it.
    private var controlStripHeight: CGFloat { 44 }
    /// Header + the 1pt `Divider` + (strip + divider when present) + the buttons.
    private func controlCardHeight(stripVisible: Bool) -> CGFloat {
        var height = controlHeaderHeight + 1 + controlButtonsHeight
        if stripVisible {
            height += controlStripHeight + 1
        }
        return height
    }

    /// The other running sessions, oldest first (what the strip offers).
    private var otherRunningSessions: [WebAppSession] {
        sessionManager.running.filter { $0.key != key }
    }

    /// One or more *other* sessions are running: the strip shows in the card.
    private var runningAppsStripVisible: Bool {
        !otherRunningSessions.isEmpty
    }

    /// Whether the live connection can carry a request right now.
    private var isConnected: Bool {
        if case .connected = monitor.state { return true }
        return false
    }

    /// Ask the server to rescan for local apps, then refresh the app lists and
    /// the icon descriptors. Same server-side call as "Refresh Apps" in the
    /// server detail. A failure is silent: the connection caption already
    /// explains a dead link, and the page is unaffected either way.
    private func refreshCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }

        await irohService.validateConnection(nodeId: nodeId)
        guard case .connected = monitor.state else { return }
        do {
            let apps = try await irohService.discoverCatalog(nodeId: nodeId)
            AppIconStore.shared.register(nodeId: nodeId, apps: apps)
            onAppsUpdated(nodeId, apps)
        } catch {
            print("[AppWebView] catalog refresh failed: \(error)")
        }
    }

    /// How *this* server's live connection reaches us, or `nil` when unknown or
    /// when the recorded path belongs to a different server.
    private var pathKind: IrohPathKind? { monitor.path?.kind(for: nodeId) }

    /// The hollow ring inside the circle: green = direct, yellow = relayed.
    private var ringColor: Color? {
        switch pathKind {
        case .direct: return .green
        case .relayed: return .yellow
        case .unknown, .none: return nil
        }
    }

    /// The caption above the app name in the expanded card.
    private var connectionLabel: (text: String, color: Color) {
        switch pathKind {
        case .direct: return ("Direct connection", .green)
        case .relayed: return ("Relayed connection", .yellow)
        case .unknown, .none: return ("Checking connection…", .secondary)
        }
    }

    /// The circle — or, when expanded, the card — that floats over the page.
    /// The circle can be dragged to any edge; it snaps there and remembers it.
    @ViewBuilder
    private func floatingControl(in size: CGSize, session: WebAppSession) -> some View {
        let base = placement.center(in: size, safeInsets: EdgeInsets(), diameter: controlDiameter)
        let dragCenter = CGPoint(
            x: base.x + dragTranslation.width,
            y: base.y + dragTranslation.height
        )

        ZStack {
            controlCircle(session: session)
                .position(dragCenter)
                .gesture(dragGesture(in: size, session: session))

            // Kept in the hierarchy while collapsed (at zero size/opacity) so the
            // card can morph out of, and back into, the circle.
            controlCard(circleCenter: base, in: size, progress: expansion, session: session)
                .allowsHitTesting(isControlExpanded)
                .accessibilityHidden(!isControlExpanded)
        }
    }

    private func controlCircle(session: WebAppSession) -> some View {
        Image(systemName: isControlExpanded ? "chevron.down" : "ellipsis")
            .font(.system(size: 18, weight: .bold))
            .frame(width: controlDiameter, height: controlDiameter)
            .contentShape(Circle())
            .glassSurface(Circle())
            .overlay {
                // A hollow ring just inside the button, so the connection type is
                // visible without expanding it. Hidden until the path is known.
                if let ringColor {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 2)
                        .frame(width: controlDiameter - 9, height: controlDiameter - 9)
                }
            }
            .accessibilityLabel(controlAccessibilityLabel(session: session))
            .accessibilityAddTraits(.isButton)
    }

    private func controlAccessibilityLabel(session: WebAppSession) -> String {
        let action = isControlExpanded ? "Hide controls" : "Show controls"
        return "\(action). \(connectionLabel.text)"
    }

    /// Tap toggles the card; a drag snaps the circle to the nearest edge.
    private func dragGesture(in size: CGSize, session: WebAppSession) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragTranslation = value.translation
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 8 {
                    // A tap: just toggle, in one animated transaction so the
                    // circle doesn't jump back to its resting spot first.
                    withAnimation(.snappy(duration: 0.2)) {
                        dragTranslation = .zero
                        isControlExpanded.toggle()
                    }
                    return
                }

                let base = placement.center(in: size, safeInsets: EdgeInsets(), diameter: controlDiameter)
                let dropped = CGPoint(
                    x: base.x + value.translation.width,
                    y: base.y + value.translation.height
                )
                let snapped = FloatingControlPlacement.snap(
                    to: dropped,
                    in: size,
                    safeInsets: EdgeInsets(),
                    diameter: controlDiameter
                )
                // Reset the drag offset and move the anchor in the *same*
                // animated transaction, so it animates from where the finger
                // was released to the snapped position (not back to the start).
                withAnimation(.snappy(duration: 0.25)) {
                    dragTranslation = .zero
                    placement = snapped
                    isControlExpanded = false
                }
                FloatingControlStore.save(snapped)
            }
    }

    /// The card, interpolated between collapsed (circle-sized, transparent, and
    /// sitting exactly on the circle) and expanded (its resting place).
    private func controlCard(circleCenter: CGPoint, in size: CGSize, progress: CGFloat, session: WebAppSession) -> some View {
        let restingCenter = cardCenter(circleCenter: circleCenter, in: size)
        let center = CGPoint(
            x: circleCenter.x + (restingCenter.x - circleCenter.x) * progress,
            y: circleCenter.y + (restingCenter.y - circleCenter.y) * progress
        )
        // Start at the circle's own size, so the two read as one shape morphing.
        let cardHeight = controlCardHeight(stripVisible: runningAppsStripVisible)
        let collapsedX = controlDiameter / controlCardWidth
        let collapsedY = controlDiameter / cardHeight
        let scaleX = collapsedX + (1 - collapsedX) * progress
        let scaleY = collapsedY + (1 - collapsedY) * progress

        let state = session.state
        return VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(connectionLabel.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(connectionLabel.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(port)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .frame(height: controlHeaderHeight)

            Divider()

            if runningAppsStripVisible {
                runningAppsStrip
                Divider()
            }

            HStack(spacing: 8) {
                refreshButton

                controlButton(
                    systemName: "chevron.backward",
                    label: "Back",
                    enabled: state.canGoBack
                ) {
                    state.goBack()
                    collapse()
                }

                controlButton(
                    systemName: "chevron.forward",
                    label: "Forward",
                    enabled: state.canGoForward
                ) {
                    state.goForward()
                    collapse()
                }

                shareButton(session: session)

                Rectangle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 1, height: 20)

                controlButton(systemName: "xmark", label: "Exit app", enabled: true) {
                    // Exit only: the session keeps running in the background
                    // (it appears in the Running list). Stopping an app is a
                    // deliberate list action (swipe / close menu there).
                    dismiss()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: controlButtonsHeight)
        }
        .frame(width: controlCardWidth)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .scaleEffect(x: scaleX, y: scaleY)
        // Fade in quickly, so the small card is visible as soon as it starts.
        .opacity(min(1, Double(progress) * 1.5))
        .position(center)
    }

    /// Reload the server's app catalog (and icons) from inside the web view.
    /// Left in the button row rather than the strip so it is available even
    /// with a single app running; the card stays open so the spinner shows.
    private var refreshButton: some View {
        Button {
            Task { await refreshCatalog() }
        } label: {
            ZStack {
                if isRefreshingCatalog {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConnected || isRefreshingCatalog)
        .opacity(isConnected ? 1 : 0.35)
        .accessibilityLabel("Refresh apps")
    }

    /// The running-apps strip: one icon per other running app (tap to swap the
    /// presented app in place; the current one stays warm). Icons only — the app
    /// name lives in the card header. Hidden when there is nothing else to
    /// switch to. Its height is `controlStripHeight`, which the card reserves
    /// exactly.
    @ViewBuilder
    private var runningAppsStrip: some View {
        if !otherRunningSessions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(otherRunningSessions, id: \.key) { other in
                        Button {
                            // The router swaps the presented session; this one
                            // stays warm.
                            onSwitchSession(other.key)
                        } label: {
                            AppIconView(
                                nodeId: other.key.nodeId,
                                app: other.key.app,
                                service: irohService,
                                size: 28
                            )
                            .frame(width: controlStripHeight, height: controlStripHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Switch to \(AppNameStore.name(nodeId: other.key.nodeId, app: other.key.app) ?? other.key.app)"
                        )
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
            }
            .frame(height: controlStripHeight)
        }
    }


    /// Where the card sits relative to the circle (toward the screen interior).
    private func cardCenter(circleCenter: CGPoint, in size: CGSize) -> CGPoint {
        let gap: CGFloat = 10
        let radius = controlDiameter / 2
        let halfWidth = controlCardWidth / 2
        let halfHeight = controlCardHeight(stripVisible: runningAppsStripVisible) / 2

        var x = circleCenter.x
        var y = circleCenter.y
        switch placement.edge {
        case .trailing: x = circleCenter.x - radius - gap - halfWidth
        case .leading: x = circleCenter.x + radius + gap + halfWidth
        case .bottom: y = circleCenter.y - radius - gap - halfHeight
        case .top: y = circleCenter.y + radius + gap + halfHeight
        }

        let margin: CGFloat = 8
        x = min(max(x, margin + halfWidth), size.width - margin - halfWidth)
        y = min(max(y, margin + halfHeight), size.height - margin - halfHeight)
        return CGPoint(x: x, y: y)
    }

    private func collapse() {
        withAnimation(.snappy(duration: 0.2)) { isControlExpanded = false }
    }

    /// A circular icon button used inside the card.
    private func controlButton(
        systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func shareButton(session: WebAppSession) -> some View {
        Button {
            collapse()
            Task { await prepareShare(session: session) }
        } label: {
            ZStack {
                if session.state.isPreparingShare {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.state.webView == nil || session.state.isPreparingShare)
        .accessibilityLabel("Share")
    }

    // MARK: - Share

    /// Build the item(s) for the system share sheet. Web pages share an adaptive
    /// item (Raemote link + PDF); every other content type shares the real file.
    private func prepareShare(session: WebAppSession) async {
        let state = session.state
        guard let webView = state.webView, let url = state.currentURL ?? session.proxyURL else { return }
        state.isPreparingShare = true
        defer { state.isPreparingShare = false }

        do {
            switch WebShare.contentKind(mimeType: state.currentMimeType) {
            case .webPage:
                let link = WebShare.raemoteURL(nodeId: nodeId, appName: appName, path: url.path)
                let pdfURL = try? await pdfSnapshotURL(from: webView)
                let source = WebPageActivityItemSource(link: link) { pdfURL }
                state.shareRequest = ShareRequest(items: [source])

            case .file:
                // Re-fetch through the loopback proxy and share the actual file,
                // so the sheet offers whatever the installed apps support.
                let (temp, response) = try await URLSession.shared.download(from: url)
                let filename = WebShare.fileFilename(
                    url: url,
                    appName: appName,
                    mimeType: response.mimeType
                )
                let dest = try WebShare.placeTemporaryFile(at: temp, filename: filename)
                state.shareRequest = ShareRequest(items: [dest])
            }
        } catch {
            state.shareError = error.localizedDescription
        }
    }

    private func pdfSnapshotURL(from webView: WKWebView) async throws -> URL {
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
        let name = WebShare.pageFilename(title: webView.title, appName: appName)
        return try WebShare.writeTemporaryFile(data, filename: name)
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let session: WebAppSession
    let appName: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        // Reuse the session's web view when it exists: a background session's
        // page must reappear exactly as it was (never a fresh blank view —
        // the load-skip rule in updateUIView depends on this).
        if let existing = session.webView {
            existing.navigationDelegate = context.coordinator
            existing.uiDelegate = context.coordinator
            session.state.webView = existing
            context.coordinator.startObserving(existing)
            return existing
        }
        let config = WKWebViewConfiguration()
        // Persistent store so cookies/localStorage survive app relaunches; the
        // stable proxy port keeps the origin stable too.
        config.websiteDataStore = .default()
        // Media apps (Jellyfin, Home Assistant) expect inline playback,
        // fullscreen, AirPlay, and the ability to autoplay.
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // WKWebView drops JS alert/confirm/prompt and new-window requests unless
        // it has a UI delegate.
        webView.uiDelegate = context.coordinator
        // The edge swipe pops back to the app list (see
        // InteractivePopGestureEnabler), so disable the web view's own
        // back/forward edge gestures to keep the gesture unambiguous.
        webView.allowsBackForwardNavigationGestures = false
        // The web view sits inside the safe area, so WebKit lays the page out
        // clear of the notch/home indicator. Match the overscroll background to
        // the system so the bands above/below never flash white.
        webView.underPageBackgroundColor = .systemBackground
        // The session strongly owns the web view (across detaches).
        session.webView = webView
        session.state.webView = webView
        context.coordinator.startObserving(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the coordinator's copy fresh so the learned-name callback and its
        // key stay current across SwiftUI re-evaluations.
        context.coordinator.parent = self
        // A re-attached (background) web view keeps its page. The loaded-URL
        // memory lives on the SESSION, not the coordinator: a re-attached view
        // gets a fresh coordinator per re-presentation, so a stale nil there
        // would reload (and reset) the warm page.
        if session.lastLoadedURL != url {
            session.lastLoadedURL = url
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Detaching the view does NOT close the session (background apps keep
        // running). The web view and its observers live on the session's state
        // and are cleaned up by the session manager on explicit close. Simply
        // clear the presenter reference.
        coordinator.stopObserving()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: WebViewRepresentable
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?
        private var fullscreenObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]

        init(_ parent: WebViewRepresentable) {
            self.parent = parent
        }

        /// Mirror the web view's history flags into observable state. KVO is used
        /// (rather than navigation callbacks) because `history.pushState` in
        /// single-page apps changes the history without a navigation event.
        func startObserving(_ webView: WKWebView) {
            canGoBackObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.parent.session.state.canGoBack = webView.canGoBack
                }
            }
            canGoForwardObservation = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.parent.session.state.canGoForward = webView.canGoForward
                }
            }
            // Hide the floating control while an element is truly fullscreen
            // (picture-in-picture does not change `fullscreenState`).
            fullscreenObservation = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] webView, _ in
                let fullscreen = webView.fullscreenState == .enteringFullscreen
                    || webView.fullscreenState == .inFullscreen
                DispatchQueue.main.async {
                    self?.parent.session.state.isFullscreen = fullscreen
                }
            }
            // The server names discovered apps from the HTML `<title>` of `GET /`,
            // which a JS-titled or auth-gated app never exposes. The live web
            // view title does, so record the first meaningful one of this visit
            // (the entry page's, before the user navigates deeper) as the app's
            // display name. Once per SESSION, not per representation: a fresh
            // coordinator on re-attach must not overwrite the recorded name
            // with a deeper page's title.
            titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let rawTitle = webView.title else { return }
                    let parent = self.parent
                    guard !parent.session.capturedTitle else { return }
                    guard AppNameStore.remember(
                        rawTitle,
                        nodeId: parent.session.key.nodeId,
                        app: parent.appName
                    ) != nil else { return }
                    parent.session.capturedTitle = true
                }
            }
        }

        func stopObserving() {
            canGoBackObservation?.invalidate()
            canGoForwardObservation?.invalidate()
            fullscreenObservation?.invalidate()
            titleObservation?.invalidate()
            canGoBackObservation = nil
            canGoForwardObservation = nil
            fullscreenObservation = nil
            titleObservation = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.session.state.isLoading = true
                self.parent.session.state.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.session.state.isLoading = false
                self.parent.session.state.currentURL = webView.url
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishNavigation(with: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishNavigation(with: error)
        }

        /// Shared failure handling: always stop the spinner, but only surface an
        /// error the user should care about. Handing a link to `WKDownload`
        /// interrupts the navigation on purpose (WebKit reports "frame load
        /// interrupted"), and that used to be shown as a load failure even
        /// though the file downloaded fine.
        private func finishNavigation(with error: Error) {
            let benign = WebNavigationError.isBenign(error)
            DispatchQueue.main.async {
                self.parent.session.state.isLoading = false
                if benign {
                    self.parent.session.state.errorMessage = nil
                } else {
                    self.parent.session.state.errorMessage = error.localizedDescription
                }
            }
        }

        // MARK: JavaScript dialogs and new windows

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            MainActor.assumeIsolated {
                let alert = UIAlertController(title: webView.title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
                guard let presenter = topViewController() else {
                    completionHandler()
                    return
                }
                presenter.present(alert, animated: true)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            MainActor.assumeIsolated {
                let alert = UIAlertController(title: webView.title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
                guard let presenter = topViewController() else {
                    completionHandler(false)
                    return
                }
                presenter.present(alert, animated: true)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            MainActor.assumeIsolated {
                let alert = UIAlertController(title: webView.title, message: prompt, preferredStyle: .alert)
                alert.addTextField { field in
                    field.text = defaultText
                    field.autocapitalizationType = .none
                    field.autocorrectionType = .no
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                    completionHandler(alert?.textFields?.first?.text ?? "")
                })
                guard let presenter = topViewController() else {
                    completionHandler(nil)
                    return
                }
                presenter.present(alert, animated: true)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // `target="_blank"` / `window.open`: load in place instead of opening
            // a new window we can't display.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// The top-most view controller, for presenting alerts.
        @MainActor
        private func topViewController() -> UIViewController? {
            var top = parent.session.state.webView?.window?.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }

        // MARK: Navigation responses

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                let mime = navigationResponse.response.mimeType
                let url = navigationResponse.response.url
                DispatchQueue.main.async {
                    self.parent.session.state.currentMimeType = mime
                    if let url { self.parent.session.state.currentURL = url }
                }
            }

            let disposition = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
            let isAttachment = disposition?.contains("attachment") == true
            if navigationResponse.isForMainFrame,
               isAttachment || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let name = WebShare.sanitize(suggestedFilename.isEmpty ? "download" : suggestedFilename)
            let dir = try? WebShare.shareDirectory()
            let dest = (dir ?? FileManager.default.temporaryDirectory).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            downloadDestinations[ObjectIdentifier(download)] = dest
            DispatchQueue.main.async {
                self.parent.session.state.downloadStarted(named: name)
            }
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
                ?? download.progress.fileURL
            DispatchQueue.main.async {
                // Clear the banner first: `dest` can be nil, and the indicator
                // must not be left behind.
                self.parent.session.state.downloadFinished()
                if let dest {
                    self.parent.session.state.shareRequest = ShareRequest(items: [dest])
                }
            }
        }

        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            DispatchQueue.main.async {
                self.parent.session.state.downloadFinished()
                self.parent.session.state.shareError = error.localizedDescription
            }
        }
    }
}

/// Applies the platform glass surface — Liquid Glass on iOS 26+, an ultra-thin
/// material otherwise — in the given shape.
private extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Re-enables the interactive edge-swipe pop gesture, which SwiftUI turns off
/// when the navigation bar is hidden. Its view controller sits in the
/// navigation hierarchy, so it can reach the enclosing `UINavigationController`.
///
/// A custom delegate allows the gesture only when there is something to pop,
/// which avoids the crash/soft-lock you otherwise get from clearing the
/// delegate on the root screen.
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let nav = Self.navigationController(for: viewController) else { return }
            coordinator.navigationController = nav
            if let gesture = nav.interactivePopGestureRecognizer {
                gesture.delegate = coordinator
                gesture.isEnabled = true
            }
        }
    }

    /// Prefer the enclosing navigation controller; fall back to searching the
    /// window's controller hierarchy (SwiftUI's internals vary by OS version).
    private static func navigationController(for viewController: UIViewController) -> UINavigationController? {
        if let nav = viewController.navigationController { return nav }
        guard var root = viewController.view.window?.rootViewController else { return nil }
        while let presented = root.presentedViewController { root = presented }
        return findNavigationController(in: root)
    }

    private static func findNavigationController(in controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        for child in controller.children {
            if let nav = findNavigationController(in: child) { return nav }
        }
        return nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
