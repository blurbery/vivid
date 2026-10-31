import SwiftUI

/// Vivid's type scale. Every size is fixed and does not follow Dynamic Type.
extension Font {
    #if os(tvOS)
    static let vividTitle = Font.system(size: 48, weight: .bold)
    static let vividHeadline = Font.system(size: 36, weight: .semibold)
    static let vividSubheadline = Font.system(size: 28, weight: .semibold)
    static let vividPosterTitle = Font.system(size: 20, weight: .medium)
    static let vividPosterMetadata = Font.system(size: 18, weight: .regular)
    static let vividBody = Font.system(size: 26)
    static let vividCaption = Font.system(size: 22, weight: .regular)
    static let vividSmall = Font.system(size: 20, weight: .regular)
    static let vividPIN = Font.system(size: 64, weight: .bold, design: .monospaced)
    #else
    static let vividTitle = Font.system(size: 18, weight: .bold)
    static let vividHeadline = Font.system(size: 16, weight: .semibold)
    static let vividSubheadline = Font.system(size: 14, weight: .bold)
    static let vividBody = Font.system(size: 14)
    static let vividCaption = Font.system(size: 12, weight: .regular)
    static let vividSmall = Font.system(size: 11, weight: .regular)
    static let vividPIN = Font.system(size: 32, weight: .bold, design: .monospaced)
    #endif
}
