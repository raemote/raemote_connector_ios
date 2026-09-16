import SwiftUI

extension Notification.Name {
    /// Posted with the scanned `raemote://` URI string as the object.
    static let qrScannerScanned = Notification.Name("raemote.qrScannerScanned")
    /// Posted when the user dismisses the scanner without scanning.
    static let qrScannerCancelled = Notification.Name("raemote.qrScannerCancelled")
}

/// A self-contained QR scanner screen.
///
/// This view owns its own state and never touches the presenting view's state
/// directly. It is hosted by `ScannerPresentation` in a detached
/// `ScannerHostingController`, so bindings back into the SwiftUI view hierarchy
/// aren't reliable. Results are broadcast through `NotificationCenter` instead,
/// which the presenting view observes with `onReceive`.
struct QRScannerScreen: View {
    @State private var isPresented = true
    @State private var scannedCode: String?
    /// The camera isn't available (denied or restricted); explain instead of
    /// vanishing.
    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            QRScannerView(
                isPresented: $isPresented,
                scannedCode: $scannedCode,
                permissionDenied: $permissionDenied
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 260, height: 260)

                Text("Point the camera at the server's QR code")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    .padding(.horizontal, 32)

                Spacer()

                Button {
                    print("[QRScannerScreen] cancelled")
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .alert("Camera Access Needed", isPresented: $permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("Raemote needs the camera to scan the server's pairing QR code. Allow camera access for Raemote in Settings, then try again — or paste the pairing link with Manual Setup instead.")
        }
        .onChange(of: scannedCode) { _, value in
            guard let value else { return }
            print("[QRScannerScreen] scanned, notifying")
            NotificationCenter.default.post(name: .qrScannerScanned, object: value)
            ScannerPresentation.dismiss()
        }
    }

    /// Dismiss the scanner and tell the presenter it was cancelled.
    private func dismiss() {
        NotificationCenter.default.post(name: .qrScannerCancelled, object: nil)
        ScannerPresentation.dismiss()
    }
}
