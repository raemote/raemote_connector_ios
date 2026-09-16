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
    /// The floating control is expanded into its card of buttons.
    var isExpanded = false
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
    let app: AppInfo
    let nodeId: String
    let irohService: IrohService
    let monitor: IrohConnectionMonitor
    /// An optional path/query to open the app with (`AppLaunchStore`), for apps
    /// whose entry URL carries a one-time token.
    var launchPath: String?
    /// Called when the app shows a page title worth remembering.
    var onNameLearned: (String) -> Void = { _ in }

    @State private var proxy: LocalProxyServer?
    @State private var proxyURL: URL?
    @State private var state = WebViewState()
    @State private var startingProxy = false
    /// The name learned from the live page title, if the app has shown one.
    @State private var learnedName: String?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    /// Where the floating control sits (persisted across launches).
    @State private var placement = FloatingControlStore.load()
    /// Live drag offset while the user moves the circle.
    @State private var dragTranslation: CGSize = .zero
    /// How far the card has morphed out of the circle: 0 = collapsed onto the
    /// circle, 1 = at its resting place. Animated when `state.isExpanded`
    /// changes; interpolating it is what makes the card grow out of the button.
    @State private var expansion: CGFloat = 0

    private let controlDiameter: CGFloat = 52

    /// What to call this app: the page title learned from the web view, else the
    /// server's name for it.
    private var displayName: String { learnedName ?? app.name }

    /// What the page is busy doing, if anything.
    private var busyText: String? {
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
        @Bindable var state = state

        // `GeometryReader` keeps the container full-screen even while the page
        // is still loading (when the only child is a small ProgressView), so the
        // controls stay pinned to the bottom instead of drifting to the center.
        GeometryReader { geometry in
            ZStack {
                if let proxyURL {
                    // Respect the safe area, like Safari: the page is laid out
                    // clear of the status bar/notch and the home indicator
                    // instead of running underneath them.
                    WebViewRepresentable(
                        url: proxyURL,
                        state: state,
                        nodeId: nodeId,
                        appName: app.name,
                        onNameLearned: { name in
                            learnedName = name
                            onNameLearned(name)
                        }
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

                if proxyURL != nil, !state.isFullscreen {
                    floatingControl(in: geometry.size)
                }

                // Any operation that takes time announces itself here: the
                // floating card collapses when it starts one, so its own
                // spinner would be hidden.
                if let busyText {
                    busyBanner(busyText)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: busyText)
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
            learnedName = AppNameStore.name(nodeId: nodeId, app: app.name)
            await connectThenStart()
            // Keep the direct/relayed indicator current while the page is open.
            await pollConnectionKind()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await revalidate() }
        }
        .onChange(of: monitor.state) { _, newState in
            if case .connected = newState, proxyURL == nil {
                Task { await startProxyIfConnected() }
            }
        }
        .onChange(of: state.isExpanded) { _, expanded in
            withAnimation(.snappy(duration: 0.3)) { expansion = expanded ? 1 : 0 }
        }
        .onDisappear {
            proxy?.stop()
            proxy = nil
        }
        .sheet(item: $state.shareRequest) { request in
            ActivityView(items: request.items)
        }
        .alert("Couldn't Share", isPresented: .constant(state.shareError != nil)) {
            Button("OK") { state.shareError = nil }
        } message: {
            if let shareError = state.shareError {
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
    /// until connected (or the view goes away).
    private func connectThenStart() async {
        while !Task.isCancelled {
            await irohService.validateConnection(nodeId: nodeId)
            if case .connected = monitor.state { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        await startProxyIfConnected()
    }

    /// Sample the transport (direct vs relayed) until the view goes away. A
    /// sample rather than a subscription: the FFI's `watchPaths` needs a tokio
    /// runtime context a Swift caller can't provide (see `refreshPathKind`).
    private func pollConnectionKind() async {
        while !Task.isCancelled {
            await irohService.refreshPathKind(nodeId: nodeId)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func startProxyIfConnected() async {
        guard proxy == nil, !startingProxy else { return }
        guard case .connected = monitor.state else { return }
        startingProxy = true
        defer { startingProxy = false }
        do {
            let server = LocalProxyServer(
                appName: app.name,
                service: irohService,
                preferredPort: ProxyPortStore.preferredPort(nodeId: nodeId, app: app.name)
            )
            let port = try await server.start()
            // Remember the port so the origin stays stable next time.
            ProxyPortStore.remember(port, nodeId: nodeId, app: app.name)
            proxy = server
            // WKWebView now talks to the in-app loopback proxy, which relays
            // every request over iroh to the raemote server. A stored launch
            // path (e.g. `/?token=…`) is included so token-gated apps start.
            proxyURL = URL(string: "http://127.0.0.1:\(port)\(launchPath ?? "/")")
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    /// On foreground, make sure the serve connection is alive and retry a page
    /// that failed while the app was suspended.
    private func revalidate() async {
        await irohService.validateConnection(nodeId: nodeId)
        if state.errorMessage != nil, let url = proxyURL {
            state.errorMessage = nil
            state.isLoading = true
            state.webView?.load(URLRequest(url: url))
        }
    }

    // MARK: - Floating control

    private var controlCardWidth: CGFloat { 268 }
    private var controlHeaderHeight: CGFloat { 50 }
    private var controlButtonsHeight: CGFloat { 54 }
    /// Header + the 1pt `Divider` + the button row.
    private var controlCardHeight: CGFloat { controlHeaderHeight + 1 + controlButtonsHeight }

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
    private func floatingControl(in size: CGSize) -> some View {
        let base = placement.center(in: size, safeInsets: EdgeInsets(), diameter: controlDiameter)
        let dragCenter = CGPoint(
            x: base.x + dragTranslation.width,
            y: base.y + dragTranslation.height
        )

        ZStack {
            controlCircle
                .position(dragCenter)
                .gesture(dragGesture(in: size))

            // Kept in the hierarchy while collapsed (at zero size/opacity) so the
            // card can morph out of, and back into, the circle.
            controlCard(circleCenter: base, in: size, progress: expansion)
                .allowsHitTesting(state.isExpanded)
                .accessibilityHidden(!state.isExpanded)
        }
    }

    private var controlCircle: some View {
        Image(systemName: state.isExpanded ? "chevron.down" : "ellipsis")
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
            .accessibilityLabel(controlAccessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private var controlAccessibilityLabel: String {
        let action = state.isExpanded ? "Hide controls" : "Show controls"
        return "\(action). \(connectionLabel.text)"
    }

    /// Tap toggles the card; a drag snaps the circle to the nearest edge.
    private func dragGesture(in size: CGSize) -> some Gesture {
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
                        state.isExpanded.toggle()
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
                    state.isExpanded = false
                }
                FloatingControlStore.save(snapped)
            }
    }

    /// The card, interpolated between collapsed (circle-sized, transparent, and
    /// sitting exactly on the circle) and expanded (its resting place).
    private func controlCard(circleCenter: CGPoint, in size: CGSize, progress: CGFloat) -> some View {
        let restingCenter = cardCenter(circleCenter: circleCenter, in: size)
        let center = CGPoint(
            x: circleCenter.x + (restingCenter.x - circleCenter.x) * progress,
            y: circleCenter.y + (restingCenter.y - circleCenter.y) * progress
        )
        // Start at the circle's own size, so the two read as one shape morphing.
        let collapsedX = controlDiameter / controlCardWidth
        let collapsedY = controlDiameter / controlCardHeight
        let scaleX = collapsedX + (1 - collapsedX) * progress
        let scaleY = collapsedY + (1 - collapsedY) * progress

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
                    Text("· \(app.port)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .frame(height: controlHeaderHeight)

            Divider()

            HStack(spacing: 12) {
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

                shareButton

                Rectangle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 1, height: 20)

                controlButton(systemName: "xmark", label: "Close app", enabled: true) {
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

    /// Where the card sits relative to the circle (toward the screen interior).
    private func cardCenter(circleCenter: CGPoint, in size: CGSize) -> CGPoint {
        let gap: CGFloat = 10
        let radius = controlDiameter / 2
        let halfWidth = controlCardWidth / 2
        let halfHeight = controlCardHeight / 2

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
        withAnimation(.snappy(duration: 0.2)) { state.isExpanded = false }
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

    private var shareButton: some View {
        Button {
            collapse()
            Task { await prepareShare() }
        } label: {
            ZStack {
                if state.isPreparingShare {
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
        .disabled(state.webView == nil || state.isPreparingShare)
        .accessibilityLabel("Share")
    }

    // MARK: - Share

    /// Build the item(s) for the system share sheet. Web pages share an adaptive
    /// item (Raemote link + PDF); every other content type shares the real file.
    private func prepareShare() async {
        guard let webView = state.webView, let url = state.currentURL ?? proxyURL else { return }
        state.isPreparingShare = true
        defer { state.isPreparingShare = false }

        do {
            switch WebShare.contentKind(mimeType: state.currentMimeType) {
            case .webPage:
                let link = WebShare.raemoteURL(nodeId: nodeId, appName: app.name, path: url.path)
                let pdfURL = try? await pdfSnapshotURL(from: webView)
                let source = WebPageActivityItemSource(link: link) { pdfURL }
                state.shareRequest = ShareRequest(items: [source])

            case .file:
                // Re-fetch through the loopback proxy and share the actual file,
                // so the sheet offers whatever the installed apps support.
                let (temp, response) = try await URLSession.shared.download(from: url)
                let filename = WebShare.fileFilename(
                    url: url,
                    appName: app.name,
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
        let name = WebShare.pageFilename(title: webView.title, appName: app.name)
        return try WebShare.writeTemporaryFile(data, filename: name)
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let state: WebViewState
    /// Which server/app this web view belongs to — the key for learned names.
    let nodeId: String
    let appName: String
    var onNameLearned: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
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
        state.webView = webView
        context.coordinator.startObserving(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the coordinator's copy fresh so the learned-name callback and its
        // key stay current across SwiftUI re-evaluations.
        context.coordinator.parent = self
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        coordinator.parent.state.webView = nil
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: WebViewRepresentable
        var lastURL: URL?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?
        private var fullscreenObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        /// The first meaningful title of this visit has been recorded.
        private var capturedTitle = false
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
                    self?.parent.state.canGoBack = webView.canGoBack
                }
            }
            canGoForwardObservation = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.parent.state.canGoForward = webView.canGoForward
                }
            }
            // Hide the floating control while an element is truly fullscreen
            // (picture-in-picture does not change `fullscreenState`).
            fullscreenObservation = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] webView, _ in
                let fullscreen = webView.fullscreenState == .enteringFullscreen
                    || webView.fullscreenState == .inFullscreen
                DispatchQueue.main.async {
                    self?.parent.state.isFullscreen = fullscreen
                }
            }
            // The server names discovered apps from the HTML `<title>` of `GET /`,
            // which a JS-titled or auth-gated app never exposes. The live web
            // view title does, so record the first meaningful one of this visit
            // (the entry page's, before the user navigates deeper) as the app's
            // display name.
            titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.capturedTitle, let rawTitle = webView.title else { return }
                    let parent = self.parent
                    guard let name = AppNameStore.remember(
                        rawTitle,
                        nodeId: parent.nodeId,
                        app: parent.appName
                    ) else { return }
                    self.capturedTitle = true
                    parent.onNameLearned(name)
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
                self.parent.state.isLoading = true
                self.parent.state.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.state.isLoading = false
                self.parent.state.currentURL = webView.url
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
                self.parent.state.isLoading = false
                if benign {
                    self.parent.state.errorMessage = nil
                } else {
                    self.parent.state.errorMessage = error.localizedDescription
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
            var top = parent.state.webView?.window?.rootViewController
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
                    self.parent.state.currentMimeType = mime
                    if let url { self.parent.state.currentURL = url }
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
                self.parent.state.downloadStarted(named: name)
            }
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
                ?? download.progress.fileURL
            DispatchQueue.main.async {
                // Clear the banner first: `dest` can be nil, and the indicator
                // must not be left behind.
                self.parent.state.downloadFinished()
                if let dest {
                    self.parent.state.shareRequest = ShareRequest(items: [dest])
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
                self.parent.state.downloadFinished()
                self.parent.state.shareError = error.localizedDescription
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
