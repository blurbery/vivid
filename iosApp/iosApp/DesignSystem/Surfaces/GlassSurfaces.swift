import SwiftUI

extension View {
    /// Liquid Glass behind the view in `shape`. Before iOS 26 the view sits on
    /// ultra-thin material instead, and the tint and interactivity are ignored.
    @ViewBuilder
    func vividGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(tvOS)
        glassEffect(GlassRecipe.make(tint: tint, interactive: interactive), in: shape)
        #else
        if #available(iOS 26, *) {
            glassEffect(GlassRecipe.make(tint: tint, interactive: interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
        #endif
    }

    /// Glass for surfaces over live video. iOS 18 to 25, and Apple TV models
    /// that can't sample video smoothly, get a flat dark fill instead.
    @ViewBuilder
    func vividPlayerGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(tvOS)
        if AppleTVPerformanceClass.isLowPower {
            background(GlassRecipe.flatPlayerFill, in: shape)
        } else {
            vividGlass(in: shape, tint: tint, interactive: interactive)
        }
        #else
        if #available(iOS 26, *) {
            vividGlass(in: shape, tint: tint, interactive: interactive)
        } else {
            background(GlassRecipe.flatPlayerFill, in: shape)
        }
        #endif
    }

    /// The emphasised glass of a menu's main action, with a bright rim.
    func vividPrimaryGlass(in shape: some InsettableShape) -> some View {
        vividGlass(in: shape, tint: .black.opacity(0.26), interactive: true)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.65), .white.opacity(0.14), .white.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }
}

private enum GlassRecipe {
    static let flatPlayerFill = Color(.sRGB, white: 0.10, opacity: 0.88)

    @available(iOS 26, tvOS 26, *)
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

#if os(tvOS)
/// Apple TV models before the Apple TV 4K (3rd generation) report a machine
/// string of `AppleTV13,x` or lower. A simulator reports the Mac's own string,
/// so it never counts as low power.
private enum AppleTVPerformanceClass {
    static let isLowPower: Bool = {
        var info = utsname()
        guard uname(&info) == 0 else { return false }
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return isLowPower(machine: machine)
    }()

    static func isLowPower(machine: String) -> Bool {
        let prefix = "AppleTV"
        guard machine.hasPrefix(prefix) else { return false }
        let generation = machine.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
        let number = Int(generation) ?? 0
        return (1...13).contains(number)
    }
}
#endif
