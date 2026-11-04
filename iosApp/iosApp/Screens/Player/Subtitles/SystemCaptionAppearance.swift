import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

/// Apple's caption settings (Settings > Accessibility > Subtitles &
/// Captioning) as a `SubtitleAppearance`, for the "use device settings"
/// appearance.
///
/// Every value MediaAccessibility returns is used. A value marked
/// `.useContentIfAvailable` still applies when the content has no style of
/// its own, and the text tracks Vivid draws have none while device settings
/// are on, so dropping those values would replace the viewer's profile with
/// Vivid's defaults.
enum SystemCaptionAppearance {

    /// Raw values read from MediaAccessibility. `nil` means the framework did
    /// not provide a value Vivid can map. Split from the mapping so tests can
    /// exercise the mapping without touching process-wide accessibility state.
    struct Snapshot: Equatable {
        var foregroundColorHex: String?
        /// 0.0–1.0.
        var foregroundOpacity: Double?
        var backgroundColorHex: String?
        /// 0.0–1.0.
        var backgroundOpacity: Double?
        var windowColorHex: String?
        /// 0.0–1.0.
        var windowOpacity: Double?
        var windowCornerRadius: Double?
        var edgeStyle: MACaptionAppearanceTextEdgeStyle?
        /// Multiplier around 1.0 (system slider spans roughly 0.5–2.0).
        var relativeCharacterSize: Double?
        var fontFamilyName: String?
        var contentOverrides: SystemCaptionContentOverrides = []
    }

    static let settingsChangedNotification =
        Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)

    /// The user's system caption style expressed as a `SubtitleAppearance`.
    static func current() -> SubtitleAppearance {
        appearance(from: snapshot())
    }

    // MARK: - Reading MediaAccessibility

    static func snapshot() -> Snapshot {
        var overrides: SystemCaptionContentOverrides = []

        // Reads one preference. Its content override is recorded whenever the
        // system says to use its value, even when the value can't be mapped.
        func read<Raw, Value>(
            _ override: SystemCaptionContentOverrides,
            _ copy: (inout MACaptionAppearanceBehavior) -> Raw,
            map: (Raw) -> Value?
        ) -> Value? {
            var behavior = MACaptionAppearanceBehavior.useValue
            let raw = copy(&behavior)
            let value = map(raw).flatMap { valueForMatchingDeviceSettings($0, behavior: behavior) }
            if behavior == .useValue { overrides.insert(override) }
            return value
        }

        var result = Snapshot()
        result.foregroundColorHex = read(.foregroundColor, {
            MACaptionAppearanceCopyForegroundColor(.user, &$0).takeRetainedValue()
        }, map: hexString(from:))
        result.foregroundOpacity = read(.foregroundOpacity, {
            MACaptionAppearanceGetForegroundOpacity(.user, &$0)
        }, map: { Double($0) })
        result.backgroundColorHex = read(.backgroundColor, {
            MACaptionAppearanceCopyBackgroundColor(.user, &$0).takeRetainedValue()
        }, map: hexString(from:))
        result.backgroundOpacity = read(.backgroundOpacity, {
            MACaptionAppearanceGetBackgroundOpacity(.user, &$0)
        }, map: { Double($0) })
        result.windowColorHex = read(.windowColor, {
            MACaptionAppearanceCopyWindowColor(.user, &$0).takeRetainedValue()
        }, map: hexString(from:))
        result.windowOpacity = read(.windowOpacity, {
            MACaptionAppearanceGetWindowOpacity(.user, &$0)
        }, map: { Double($0) })
        result.windowCornerRadius = read(.windowCornerRadius, {
            MACaptionAppearanceGetWindowRoundedCornerRadius(.user, &$0)
        }, map: { Double($0) })
        result.edgeStyle = read(.edge, {
            MACaptionAppearanceGetTextEdgeStyle(.user, &$0)
        }, map: { $0 })
        result.relativeCharacterSize = read(.size, {
            MACaptionAppearanceGetRelativeCharacterSize(.user, &$0)
        }, map: { Double($0) })
        result.fontFamilyName = read(.font, {
            MACaptionAppearanceCopyFontDescriptorForStyle(.user, &$0, .default).takeRetainedValue()
        }, map: fontFamilyName(of:))
        result.contentOverrides = overrides
        return result
    }

    /// The family of the caption font chosen in Accessibility. The descriptor
    /// MediaAccessibility returns names the font ("TrebuchetMS-Bold") but not
    /// its family, so resolve it to a real font first. Apple's private system
    /// faces (".AppleSystemUIFont", the default caption font) can't be named
    /// to libass or SwiftUI, so they stay on Vivid's sans-serif.
    static func fontFamilyName(of descriptor: CTFontDescriptor) -> String? {
        let named = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        let family = named ?? (CTFontCopyFamilyName(CTFontCreateWithFontDescriptor(descriptor, 0, nil)) as String)
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else { return nil }
        return trimmed
    }

    /// Resolve a value for Vivid's explicit "Use Device Settings" mode.
    ///
    /// `.useContentIfAvailable` is a precedence rule, not an absent value:
    /// Apple's contract says to use the returned preference when the content
    /// has no competing style. Plain SRT/VTT and other controlled text tracks
    /// have no authored appearance, so both known behaviors resolve to the
    /// system value. Native ASS uses each returned behavior downstream to
    /// preserve authored styling or apply the system category as requested.
    static func valueForMatchingDeviceSettings<Value>(
        _ value: Value,
        behavior: MACaptionAppearanceBehavior
    ) -> Value? {
        switch behavior {
        case .useValue, .useContentIfAvailable:
            return value
        @unknown default:
            return nil
        }
    }

    // MARK: - Mapping

    /// Fold a system snapshot over a base appearance. Field-by-field:
    /// customized values win, everything else keeps the base.
    ///
    static func appearance(
        from snapshot: Snapshot,
        base: SubtitleAppearance = .default
    ) -> SubtitleAppearance {
        var result = base

        // Apple's glyph background and caption window are independent
        // layers. Keep both rather than folding the window over the glyph
        // background (which previously lost one of the user's colors).
        if let opacity = snapshot.backgroundOpacity, opacity > 0.01 {
            result.backgroundStyle = .box
            result.backgroundOpacity = Int((opacity * 100).rounded())
            if let background = snapshot.backgroundColorHex {
                result.backgroundColor = background
            }
        } else if snapshot.backgroundOpacity != nil {
            result.backgroundStyle = SubtitleBackgroundStylePreset.none
        }

        if let window = snapshot.windowColorHex {
            result.captionWindowColor = window
        }
        if let opacity = snapshot.windowOpacity {
            result.captionWindowOpacity = Int((opacity * 100).rounded())
        }
        if let radius = snapshot.windowCornerRadius {
            result.captionWindowCornerRadius = radius
        }

        if let edge = snapshot.edgeStyle {
            switch edge {
            case .uniform:
                result.systemTextEdgeStyle = .uniform
                result.textOutline = true
            case .raised:
                result.systemTextEdgeStyle = .raised
                result.textOutline = true
            case .depressed:
                result.systemTextEdgeStyle = .depressed
                result.textOutline = true
            case .dropShadow:
                result.systemTextEdgeStyle = .dropShadow
                result.textOutline = false
            case .none, .undefined:
                result.systemTextEdgeStyle = SystemCaptionTextEdgeStyle.none
                result.textOutline = false
            @unknown default:
                result.systemTextEdgeStyle = nil
            }
        }

        if let foreground = snapshot.foregroundColorHex {
            result.fontColor = foreground
        }
        if let opacity = snapshot.foregroundOpacity {
            result.fontOpacity = Int((opacity * 100).rounded())
        }
        if let relativeSize = snapshot.relativeCharacterSize {
            result.systemRelativeFontScale = relativeSize
            result.fontSize = fontSizePreset(forRelativeSize: relativeSize)
        }
        if let family = snapshot.fontFamilyName,
           let preset = SubtitleFontFamilyPreset(rawValue: family) {
            result.fontFamily = preset
        }
        result.systemContentOverrides = snapshot.contentOverrides

        return result.sanitized()
    }

    /// Map the system's relative character size (1.0 = default) onto our
    /// preset ladder, anchoring 1.0 at the Vivid default preset.
    static func fontSizePreset(forRelativeSize relative: Double) -> SubtitleFontSizePreset {
        let anchors: [(preset: SubtitleFontSizePreset, relative: Double)] = [
            (.small, 0.6),
            (.medium, 0.8),
            (.large, 1.0),
            (.xlarge, 1.4),
            (.xxlarge, 1.8),
        ]
        return anchors.min(by: { abs($0.relative - relative) < abs($1.relative - relative) })?.preset
            ?? SubtitleAppearance.default.fontSize
    }

    /// `#RRGGBB` from a CGColor, converted through sRGB. Alpha is carried
    /// separately by the opacity preferences, so it is dropped here.
    static func hexString(from color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }
        func byte(_ value: CGFloat) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(
            format: "#%02x%02x%02x",
            byte(components[0]), byte(components[1]), byte(components[2])
        )
    }
}
