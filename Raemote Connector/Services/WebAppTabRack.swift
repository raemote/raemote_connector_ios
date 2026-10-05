import SafariServices
import SwiftUI
import UIKit

/// The warm multi-app "tab rack": one retained view controller per live
/// session, kept alive **off-window** so background apps keep running like
/// real Safari tabs (JS timers, WebSockets, audio — page visibility hidden,
/// exactly like a background Safari tab).
///
/// Ownership: the rack is owned by `WebAppSessionManager` (one tree:
/// manager → session → tab controller), so every path that ends a session —
/// user close, LRU session eviction, server removal, `closeAll` — destroys
/// its tab exactly once via `destroy(for:)`. Memory pressure destroys only a
/// *background* page (see `evictWarmPageUnderPressure`); the session stays.
///
/// Containment: every controller is a child of one container (`rackVC`) for
/// its whole life — views stacked, only the active tab unhidden. While the
/// app screen is up, `rackVC` is mounted under the screen's host; when the
/// screen goes away (Done/pop), `unmount()` takes `rackVC` out of the window
/// while the whole subtree stays retained here — pages keep running.
///
/// The factory is injectable so tests exercise the lifecycle with plain
/// view controllers instead of spinning up real `SFSafariViewController`s.
@MainActor
final class WebAppTabRack {
    /// Builds the per-URL tab controller (defaults to `SFSafariViewController`).
    typealias Factory = (URL) -> UIViewController

    /// The container parenting every tab controller for its whole life.
    private let rackVC = UIViewController()
    private var controllers: [WebAppSessionKey: UIViewController] = [:]
    private var delegates: [WebAppSessionKey: RackTabDelegate] = [:]
    private let factory: Factory

    /// The tab whose page is currently visible (the mounted one).
    private var activeKey: WebAppSessionKey?
    /// Set on mount: leaving the screen via the active tab's Done.
    private var onFinish: (() -> Void)?

    init(factory: Factory? = nil) {
        // Default argument expressions are evaluated outside the main actor,
        // so the real SFVC factory is chosen in the body instead.
        self.factory = factory ?? { SFSafariViewController(url: $0) }
        rackVC.view.backgroundColor = .clear
    }

    // MARK: - Tab lifecycle (create / destroy)

    /// The warm controller for `key`, creating it from `url` on first use and
    /// reusing it forever after — this is what makes switching instant and
    /// state-preserving. A destroyed (closed / evicted) tab starts fresh on
    /// its next mount.
    func controller(for key: WebAppSessionKey, url: URL) -> UIViewController {
        if let existing = controllers[key] { return existing }
        let vc = factory(url)
        controllers[key] = vc
        rackVC.addChild(vc)
        // Constraints, not frames: SwiftUI can mount before it has sized the
        // representable, and a view laid out from a zero-sized container via
        // autoresizing never grows back (proportional springs from a 0 base)
        // — the tab would sit at 0×0 forever, i.e. a blank screen.
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        rackVC.view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: rackVC.view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: rackVC.view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: rackVC.view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: rackVC.view.bottomAnchor),
        ])
        vc.didMove(toParent: rackVC)
        // Hidden until it is (or becomes) the active tab.
        vc.view.isHidden = true
        if let safari = vc as? SFSafariViewController {
            let delegate = RackTabDelegate(rack: self, key: key)
            safari.delegate = delegate
            delegates[key] = delegate
        }
        return vc
    }

    func hasController(for key: WebAppSessionKey) -> Bool {
        controllers[key] != nil
    }

    var controllerCount: Int { controllers.count }

    /// Whether `rackVC` is currently attached to a screen (app screen up).
    var isMounted: Bool { rackVC.parent != nil }

    /// Tear down `key`'s tab: leaves the hierarchy, is released, and will be
    /// recreated from scratch next time. No-op for unknown keys.
    func destroy(for key: WebAppSessionKey) {
        guard let vc = controllers.removeValue(forKey: key) else { return }
        delegates.removeValue(forKey: key)
        vc.willMove(toParent: nil)
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        if activeKey == key { activeKey = nil }
    }

    func destroyAll() {
        for key in Array(controllers.keys) {
            destroy(for: key)
        }
    }

    // MARK: - Mounting (app screen on/off window)

    /// Sync the rack with the screen: parent `rackVC` under `host`, make the
    /// tab for `activeKey` visible (creating it from `activeURL` if needed —
    /// this self-heals a memory-evicted page on re-present), hide the rest,
    /// and remember how to route Done.
    func mount(
        into host: UIViewController,
        activeKey: WebAppSessionKey?,
        activeURL: URL?,
        onFinish: @escaping () -> Void
    ) {
        if rackVC.parent !== host {
            if rackVC.parent != nil {
                rackVC.willMove(toParent: nil)
                rackVC.view.removeFromSuperview()
                rackVC.removeFromParent()
            }
            host.addChild(rackVC)
            rackVC.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(rackVC.view)
            // Pinned to the screen's bounds — resolves at layout time even if
            // SwiftUI has not sized `host.view` yet (see `controller(for:)`).
            NSLayoutConstraint.activate([
                rackVC.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                rackVC.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                rackVC.view.topAnchor.constraint(equalTo: host.view.topAnchor),
                rackVC.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            ])
            rackVC.didMove(toParent: host)
        }
        self.onFinish = onFinish
        self.activeKey = activeKey
        if let activeKey, let activeURL {
            _ = controller(for: activeKey, url: activeURL)
        }
        updateVisibility()
    }

    /// Detach the whole subtree from the window (the screen is going away).
    /// Controllers stay parented to `rackVC` — the pages keep running.
    func unmount() {
        onFinish = nil
        activeKey = nil
        guard rackVC.parent != nil else { return }
        rackVC.willMove(toParent: nil)
        rackVC.view.removeFromSuperview()
        rackVC.removeFromParent()
    }

    private func updateVisibility() {
        for (key, vc) in controllers {
            vc.view.isHidden = (key != activeKey)
        }
    }

    /// The active tab's Done button (or edge-swipe dismiss) was used. Only the
    /// active tab can really get here, but a stale callback from a
    /// background tab must never dismiss the screen — guard on identity.
    func tabDidFinish(_ key: WebAppSessionKey) {
        guard activeKey == key, let onFinish else { return }
        onFinish()
    }
}

/// Per-tab `SFSafariViewController` delegate; holds the rack weakly (the rack
/// owns the delegate, so a strong reference here would be a cycle).
private final class RackTabDelegate: NSObject, SFSafariViewControllerDelegate {
    weak var rack: WebAppTabRack?
    let key: WebAppSessionKey

    init(rack: WebAppTabRack, key: WebAppSessionKey) {
        self.rack = rack
        self.key = key
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        rack?.tabDidFinish(key)
    }
}

/// SwiftUI mount point for the rack: a stable representable whose identity
/// must **not** depend on the session key — key switches are handled inside
/// the rack (toggle visible tab), not by recreating the mount.
struct RackMountView: UIViewControllerRepresentable {
    let rack: WebAppTabRack
    let activeKey: WebAppSessionKey?
    let activeURL: URL?
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(rack: rack)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        rack.mount(
            into: host,
            activeKey: activeKey,
            activeURL: activeURL,
            onFinish: onFinish
        )
    }

    /// The screen is going away (Done, back, pop): detach the rack's subtree
    /// from the window. The rack — and every tab — stays alive.
    static func dismantleUIViewController(
        _ host: UIViewController,
        coordinator: Coordinator
    ) {
        coordinator.rack.unmount()
    }

    final class Coordinator {
        let rack: WebAppTabRack
        init(rack: WebAppTabRack) {
            self.rack = rack
        }
    }
}
