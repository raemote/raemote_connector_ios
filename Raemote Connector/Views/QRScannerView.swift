@preconcurrency import AVFoundation
import SwiftUI

/// A view whose backing layer is an `AVCaptureVideoPreviewLayer`, so the live
/// camera image resizes automatically with Auto Layout.
final class QRPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }
}

/// Presents a live camera preview and reports the first QR code it sees.
///
/// Set `scannedCode` when detection succeeds and `isPresented` back to `false`
/// to dismiss. The session is stopped automatically when the view goes away.
/// If the camera can't be used, `permissionDenied` is set instead of dismissing
/// silently, so the caller can explain why.
struct QRScannerView: UIViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var scannedCode: String?
    @Binding var permissionDenied: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPresented: $isPresented,
            scannedCode: $scannedCode,
            permissionDenied: $permissionDenied
        )
    }

    func makeUIView(context: Context) -> QRPreviewView {
        QRPreviewView()
    }

    func updateUIView(_ uiView: QRPreviewView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: QRPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    nonisolated final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let metadataOutput = AVCaptureMetadataOutput()
        private let sessionQueue = DispatchQueue(label: "com.raemote.qrscanner.session")
        private var configured = false

        private let isPresented: Binding<Bool>
        private let scannedCode: Binding<String?>
        private let permissionDenied: Binding<Bool>

        init(
            isPresented: Binding<Bool>,
            scannedCode: Binding<String?>,
            permissionDenied: Binding<Bool>
        ) {
            self.isPresented = isPresented
            self.scannedCode = scannedCode
            self.permissionDenied = permissionDenied
            super.init()
        }

        /// Connects the session to the preview and starts scanning once.
        @MainActor func attach(to preview: QRPreviewView) {
            preview.setSession(session)
            guard !configured else { return }
            configured = true
            Task { await begin() }
        }

        func stop() {
            let session = self.session
            sessionQueue.async {
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }

        private func begin() async {
            let authorized = await ensurePermission()
            print("[QRScanner] camera authorized: \(authorized)")
            guard authorized else {
                // The caller explains this; dismissing here would look like a
                // crash. The screen keeps its own Cancel button.
                await MainActor.run { permissionDenied.wrappedValue = true }
                return
            }

            // Configuring and starting the session both block for a noticeable
            // time on device, so keep every session mutation on the serial session
            // queue instead of the main thread.
            sessionQueue.async { [self] in
                configureIfNeeded()
                if !session.isRunning {
                    print("[QRScanner] starting capture session")
                    session.startRunning()
                    print("[QRScanner] capture session running=\(session.isRunning)")
                }
            }
        }

        private func ensurePermission() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                return true
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: .video)
            default:
                return false
            }
        }

        private func configureIfNeeded() {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
            else {
                print("[QRScanner] no usable back camera input")
                return
            }
            session.addInput(input)

            // The output must be added before setting metadataObjectTypes; the
            // available types depend on the session's configured inputs.
            guard session.canAddOutput(metadataOutput) else {
                print("[QRScanner] cannot add metadata output")
                return
            }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]
            print("[QRScanner] session configured")
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            print("[QRScanner] detected code, length=\(value.count)")

            Task { @MainActor in
                self.scannedCode.wrappedValue = value
                self.isPresented.wrappedValue = false
                self.stop()
            }
        }
    }
}
