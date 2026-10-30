import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A sharp QR code for `content`, or a clear square when it can't be made.
struct QRCodeView: View {
    let content: String
    var size: CGFloat = 240

    private static let context = CIContext()

    var body: some View {
        Group {
            if let image = Self.makeImage(content) {
                Image(platformImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }

    private static func makeImage(_ content: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return PlatformImage.vividImage(cgImage: cgImage)
    }
}
