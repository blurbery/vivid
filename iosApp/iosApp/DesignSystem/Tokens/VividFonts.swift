import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// Vivid's type scale. Every size is fixed and does not follow Dynamic Type.
extension Font {
    #if os(tvOS)
    static let vividTitle = Font.system(size: 48, weight: .bold)
    static let vividHeadline = Font.system(size: 36, weight: .semibold)
    static let vividSubheadline = Font.system(size: 28, weight: .semibold)
    /// Captions under portrait posters.
    static let vividPosterTitle = TVCardCaptionText.posterTitle.font
    static let vividPosterMetadata = TVCardCaptionText.posterMetadata.font
    /// Captions under landscape cards: Continue Watching, Next Up, episode
    /// rows and the Library tab's library cards.
    static let vividLandscapeCardTitle = TVCardCaptionText.landscapeTitle.font
    static let vividLandscapeCardMetadata = TVCardCaptionText.landscapeMetadata.font
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

#if os(tvOS)
/// One line of an Apple TV card caption. The size and weight are defined
/// once here, for both the font a card draws and the line height Home rows
/// reserve for it.
struct TVCardCaptionText: Sendable {
    enum Weight: Sendable {
        case regular
        case medium
    }

    let size: CGFloat
    let weight: Weight
    /// The height of one line, rounded up to a whole point.
    let lineHeight: CGFloat

    private init(size: CGFloat, weight: Weight) {
        self.size = size
        self.weight = weight
        let fontWeight: UIFont.Weight
        switch weight {
        case .regular: fontWeight = .regular
        case .medium: fontWeight = .medium
        }
        lineHeight = UIFont.systemFont(ofSize: size, weight: fontWeight).lineHeight.rounded(.up)
    }

    static let posterTitle = TVCardCaptionText(size: 24, weight: .medium)
    static let posterMetadata = TVCardCaptionText(size: 22, weight: .regular)
    static let landscapeTitle = TVCardCaptionText(size: 24, weight: .medium)
    static let landscapeMetadata = TVCardCaptionText(size: 22, weight: .regular)

    var font: Font {
        switch weight {
        case .regular: return Font.system(size: size, weight: .regular)
        case .medium: return Font.system(size: size, weight: .medium)
        }
    }
}
#endif
