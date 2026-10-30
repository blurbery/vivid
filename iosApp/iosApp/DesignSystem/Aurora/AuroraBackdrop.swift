import SwiftUI

// MARK: - Variants
//
// Each first-run screen gets a slightly different placement of Vivid's cool
// signal glow. The canvas stays mostly black so authentication transitions
// naturally into the signed-in media experience.

struct AuroraVariant {
    var glowCenter: UnitPoint
    var lineHeight: CGFloat
    var intensity: Double

    static let server = AuroraVariant(glowCenter: UnitPoint(x: 0.18, y: 0.30), lineHeight: 0.56, intensity: 0.72)
    static let signIn = AuroraVariant(glowCenter: UnitPoint(x: 0.78, y: 0.25), lineHeight: 0.47, intensity: 0.86)
    static let profile = AuroraVariant(glowCenter: UnitPoint(x: 0.50, y: 0.42), lineHeight: 0.58, intensity: 0.72)
}

enum AuroraScrim {
    /// Radial darkening at the edges so a centered glass card pops.
    case soft
}
