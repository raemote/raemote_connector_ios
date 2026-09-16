import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a QR code for a string using CoreImage (no third-party dependency).
enum QRCodeImage {
    /// A QR image for `string`, or `nil` if it can't be generated.
    static func make(from string: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
