import SwiftUI
import UIKit

/// A hosting controller that locks the interface to portrait and prevents rotation
/// while it is the topmost full-screen modal.
///
/// `supportedInterfaceOrientations` constrains rotation on iPhone; `prefersInterfaceOrientationLocked`
/// is the scene-level preference Apple recommends for temporarily locking orientation
/// (see TN3192). The geometry request rotates an already-landscape scene back to portrait.
final class ScannerHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .portrait
    }

    override var prefersInterfaceOrientationLocked: Bool {
        true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Re-evaluate the orientation constraints once the scanner is on screen.
        // We deliberately avoid `requestGeometryUpdate` here: forcing a geometry
        // change while the presentation transition is settling stalls the main
        // thread. `supportedInterfaceOrientations` + `prefersInterfaceOrientationLocked`
        // keep the scanner in portrait.
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 26.0, *) {
            setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }
}

/// Presents a full-screen, portrait-locked `ScannerHostingController` from the active
/// window.
///
/// This deliberately bypasses SwiftUI's presentation machinery. A `UIViewControllerRepresentable`
/// used only as a presentation anchor never reliably enters the window hierarchy, so
/// presenting from it is flaky. Presenting from the window's topmost view controller is
/// deterministic and keeps the scanner's own view controller on top (which is what makes
/// the orientation lock effective).
@MainActor
enum ScannerPresentation {
    private static var presented: UIViewController?

    static func present<Content: View>(@ViewBuilder content: () -> Content) {
        guard presented == nil else {
            print("[ScannerPresentation] already presenting; ignoring")
            return
        }
        guard let scene = activeScene else {
            print("[ScannerPresentation] no window scene")
            return
        }
        guard let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            print("[ScannerPresentation] no window")
            return
        }
        guard let root = window.rootViewController else {
            print("[ScannerPresentation] no root view controller")
            return
        }

        let controller = ScannerHostingController(rootView: content())
        controller.modalPresentationStyle = .fullScreen
        presented = controller
        print("[ScannerPresentation] presenting from \(type(of: root.topmostPresented))")
        root.topmostPresented.present(controller, animated: true) {
            print("[ScannerPresentation] presented")
        }
    }

    static func dismiss() {
        guard let controller = presented else { return }
        presented = nil
        controller.dismiss(animated: true) {
            print("[ScannerPresentation] dismissed")
        }
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

private extension UIViewController {
    var topmostPresented: UIViewController {
        presentedViewController?.topmostPresented ?? self
    }
}
