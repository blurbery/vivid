import SwiftUI
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension PlatformImage {
    static func vividImage(cgImage: CGImage) -> PlatformImage {
        UIImage(cgImage: cgImage)
    }
}
