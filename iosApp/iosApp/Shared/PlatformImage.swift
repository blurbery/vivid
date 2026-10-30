#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

#if canImport(UIKit)
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    static func vividImage(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return PlatformImage(cgImage: cgImage)
        #endif
    }

    static func vividImage(data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }
}
