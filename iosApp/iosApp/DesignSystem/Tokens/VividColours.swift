import SwiftUI

/// Vivid's palette. Most colours are sRGB values written as 0 to 255
/// channels; the rest are white at an opacity, a grey level or a system colour.
extension Color {
    private static func srgb(_ red: Double, _ green: Double, _ blue: Double, opacity: Double = 1) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: opacity)
    }

    // Page and surface fills
    static let vividBackground = srgb(0, 0, 0)
    static let vividSurface = srgb(10, 10, 10)
    static let vividSurfaceVariant = srgb(14, 15, 18)
    static let vividSurfaceElevated = srgb(21, 23, 28)

    // Text and emphasis
    static let vividPrimary = srgb(237, 237, 237)
    static let vividOnSurface = srgb(237, 237, 237)
    static let vividSecondaryText = srgb(237, 237, 237, opacity: 153 / 255)
    static let vividAccent = srgb(120, 174, 252)
    static let vividBrandOrange = srgb(253, 116, 3)

    // Status
    static let vividError = srgb(176, 0, 32)
    static let vividSuccess = Color.green
    static let vividWarning = srgb(255, 193, 7)

    // Chips, toggles and other chrome on dark pages
    static let vividChromeSelectedFill = Color.white.opacity(0.14)
    static let vividChromeSelectedBorder = Color.white.opacity(0.10)
    static let vividChromeRestingFill = Color.white.opacity(0.07)
    static let vividChromeRestingBorder = Color.white.opacity(0.09)

    // Request states
    static let requestAmber = srgb(245, 158, 11)
    static let requestSky = srgb(56, 189, 248)
    static let requestEmerald = srgb(52, 211, 153)
    static let requestRose = srgb(251, 113, 133)

    // Hairlines
    static let vividOutline = Color.white.opacity(0.12)
    static let vividDivider = Color.white.opacity(0.12)

    // First-run screens
    static let auroraInk = vividOnSurface
    static let auroraAccent = Color(.sRGB, white: 0.88)
    static let auroraInkSecondary = auroraInk.opacity(0.62)
    static let auroraInkTertiary = auroraInk.opacity(0.40)
}

extension Color {
    /// Reads hex colour text such as `#RRGGBB` or `#AARRGGBB`. Punctuation
    /// such as `#` is trimmed from both ends, then six characters read as RGB
    /// and eight as ARGB; any other length gives opaque black. A leading `0x`
    /// is skipped when reading digits but still counts towards the length,
    /// so `0xRRGGBB` reads as ARGB with alpha 0.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var digits = Substring(trimmed)
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
        }
        var value: UInt64 = 0
        for character in digits {
            guard character.isASCII, let digit = character.hexDigitValue else { break }
            value = value &* 16 &+ UInt64(digit)
        }
        let alpha, red, green, blue: UInt64
        switch trimmed.count {
        case 6:
            (alpha, red, green, blue) = (255, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        case 8:
            (alpha, red, green, blue) = (value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default:
            (alpha, red, green, blue) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}
