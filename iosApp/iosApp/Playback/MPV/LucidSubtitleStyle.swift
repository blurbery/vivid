// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if os(iOS) || os(tvOS)
import CoreText
import UIKit

/// Plain text styling only; authored ASS and bitmap layout stays with Lucid.
///
/// The overlay that draws external text files is the designed look, so
/// libass is set up to match it: every value here is worked out from the
/// same `VividSubtitleRenderStyle` and the overlay's own sizes. libass works
/// in scaled pixels of a 720-line video and the overlay in points of a
/// 1080-line one, so overlay sizes are multiplied by 2/3.
///
/// libass can't draw these, so they stay different: rounded box and window
/// corners, the soft drop shadow (a hard one stands in), an edge or shadow
/// on the glyphs together with a box (libass pads the box with the shadow
/// offset), separate horizontal and vertical box padding, Apple's SF font
/// (bold Helvetica Neue, Times New Roman and Menlo stand in), the
/// overlay's line breaks (libass balances lines, and `sub-ass-override=no`
/// keeps its wrap style), a secondary subtitle at the top, which libass
/// draws in the primary's place, and text after a bold span in an embedded
/// SubRip or WebVTT track: FFmpeg closes the span with `\b0`, so that text
/// comes out regular beside the bold stand-in. As in the overlay, a
/// secondary subtitle sits a fixed 17% up, so a primary of two lines or
/// more can overlap it.
enum LucidSubtitleStyle {
    /// The video as shown, in points. mpv fits it inside the layer whatever
    /// the Zoom setting, and libass draws inside that rectangle.
    struct Geometry: Equatable {
        let videoHeight: Double
        let videoAspect: Double

        init(videoHeight: Double, videoAspect: Double) {
            // Rounded, so layout passes that don't really move it compare equal.
            self.videoHeight = videoHeight.rounded()
            self.videoAspect = (videoAspect * 100).rounded() / 100
        }

        init?(layer: CGSize, picture: CGSize?) {
            guard layer.width > 0, layer.height > 0,
                  let picture, picture.width > 0, picture.height > 0 else { return nil }
            let aspect = picture.width / picture.height
            self.init(videoHeight: min(layer.height, layer.width / aspect), videoAspect: aspect)
        }
    }

    /// The face libass draws with in place of the overlay's font.
    struct Face: Equatable {
        let name: String
        let bold: Bool
        /// libass sizes a face by its usWinAscent + usWinDescent (as
        /// VSFilter does) rather than its em: that height per em.
        let assHeightPerEm: Double
        /// The line height per em of the font the overlay draws with.
        let overlayLineHeightPerEm: Double
    }

    private static let scale = 720.0 / 1080.0

    static func options(_ value: SubtitleAppearance, geometry: Geometry? = nil, face: Face? = nil) -> [String: String] {
        let style = VividSubtitleRenderStyle(appearance: value)
        let face = face ?? Self.face(for: style.fontFamily)
        // The overlay's minimum sizes are points on screen, so they only
        // matter on a small picture, such as an iPhone's.
        let points = geometry.map { $0.videoHeight / 1_080 } ?? 0
        func overlay(_ size: Double, minimumPoints: Double) -> Double {
            points > 0 ? max(size, minimumPoints / points) : size
        }
        let fontSize = overlay(style.fontSizeAt1080Lines, minimumPoints: 8)
        let edge = overlay(min(2, style.fontSizeAt1080Lines * 0.03), minimumPoints: 0.5)
        let hasWindow = style.windowOpacity > 0
        let boxed = style.drawsBox || hasWindow
        let padX = (style.drawsBox ? overlay(10, minimumPoints: 6) : 0) + (hasWindow ? overlay(6, minimumPoints: 4) : 0)
        let padY = (style.drawsBox ? overlay(5, minimumPoints: 3) : 0) + (hasWindow ? overlay(4, minimumPoints: 3) : 0)
        let fade = style.foregroundOpacity

        // The overlay's four stacked outline shadows reach twice their offset.
        let outline = style.drawsOutline ? 2 * edge * scale : 0
        let shadow: Double
        let back: String
        if boxed {
            // The box reaches past the outline by the shadow offset. It also
            // makes up the two fonts' different line heights, so the box is
            // as tall as the overlay's.
            let lineGap = (face.overlayLineHeightPerEm - face.assHeightPerEm) * fontSize / 2
            shadow = max(0, (padY + lineGap) * scale - outline)
            back = boxColour(style)
        } else if style.drawsRaisedEdge {
            shadow = -edge * scale
            back = colour(.white, opacity: 0.8 * fade)
        } else if style.drawsDepressedEdge {
            shadow = edge * scale
            back = colour(.black, opacity: 0.9 * fade)
        } else if style.drawsDropShadow {
            shadow = 2
            back = colour(.black, opacity: 0.85 * fade)
        } else {
            shadow = 0
            back = colour(.black, opacity: 0)
        }

        // Lines wrap at 86% of the video's width, less the box's padding.
        // mpv turns sub-margin-x into 1/960 of the video's width per unit.
        let width = 720 * (geometry?.videoAspect ?? 16.0 / 9.0)
        let marginX = (0.07 * width + padX * scale) * 960 / width
        var options = [
            "sub-ass-override": "no", "secondary-sub-ass-override": "no",
            "sub-font": face.name,
            "sub-bold": face.bold ? "yes" : "no",
            "sub-font-size": number(fontSize * scale * face.assHeightPerEm),
            "sub-color": colour(style.foreground, opacity: fade),
            "sub-border-style": boxed ? "background-box" : "outline-and-shadow",
            "sub-back-color": back,
            "sub-outline-color": colour(style.outlineColor, opacity: fade),
            "sub-outline-size": number(outline),
            "sub-shadow-offset": number(shadow),
            "sub-margin-x": String(assMargin(marginX)),
            "sub-scale-with-window": "no", "sub-use-margins": "no"
        ]
        // The overlay places the box, or the text without one, 8% in from
        // the edge (27% up for Lower Third); a secondary subtitle sits 17%
        // (36%) up, above the primary. A top line, including a cue a file
        // moves up with {\an8}, is placed by the margin alone; a bottom line
        // by sub-pos, which puts the bottom of the text that share of the
        // way from the top to the margin.
        let reach = boxed ? outline + shadow : 0
        let marginY = assMargin(57.6 + reach)
        let kept = Double(Int(Double(marginY) * 0.4)) * 2.5
        let (primary, secondary) = style.position == .lowerThird ? (27.0, 36.0) : (8.0, 17.0)
        func bottomLine(_ inset: Double) -> String { number(100 * (720 * (1 - inset / 100) - reach) / (720 - kept)) }
        options["sub-align-y"] = style.position == .top ? "top" : "bottom"
        options["sub-margin-y"] = String(marginY)
        options["sub-pos"] = bottomLine(primary)
        options["secondary-sub-pos"] = bottomLine(secondary)
        return options
    }

    /// The face for a family, with the metrics read from the installed font.
    /// libass can't load Apple's SF, so the generic families use the closest
    /// installed faces in bold, nearer the overlay's semibold SF than their
    /// regular weight. libass finds Apple's own faces by family through
    /// CoreText and asks for regular or bold only, so a Medium face can't be
    /// named: "Helvetica Neue Medium" comes out as the regular weight.
    static func face(for family: VividSubtitleRenderStyle.FontFamily) -> Face {
        switch family {
        case .sansSerif:
            return face(name: "Helvetica Neue", postScriptName: "HelveticaNeue-Bold", bold: true, design: .default)
        case .serif:
            return face(name: "Times New Roman", postScriptName: "TimesNewRomanPS-BoldMT", bold: true, design: .serif)
        case .monospace:
            return face(name: "Menlo", postScriptName: "Menlo-Bold", bold: true, design: .monospaced)
        case .custom(let name):
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
            let found = CTFontCopyFamilyName(font) as String == name
            return Face(name: name, bold: false,
                        assHeightPerEm: found ? assHeightPerEm(font) : 1.15,
                        overlayLineHeightPerEm: found ? lineHeightPerEm(font) : 1.15)
        }
    }

    private static func face(name: String, postScriptName: String, bold: Bool,
                             design: UIFontDescriptor.SystemDesign) -> Face {
        let font = CTFontCreateWithName(postScriptName as CFString, 100, nil)
        let found = CTFontCopyPostScriptName(font) as String == postScriptName
        let system = UIFont.systemFont(ofSize: 100, weight: .semibold)
        let overlayFont = system.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: 100) } ?? system
        return Face(name: name, bold: bold, assHeightPerEm: found ? assHeightPerEm(font) : 1.15,
                    overlayLineHeightPerEm: overlayFont.lineHeight / 100)
    }

    /// usWinAscent + usWinDescent from the OS/2 table, as libass reads them,
    /// or the ascent and descent FreeType would use without them.
    private static func assHeightPerEm(_ font: CTFont) -> Double {
        let unitsPerEm = Double(CTFontGetUnitsPerEm(font))
        if unitsPerEm > 0, let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           table.count >= 78 {
            let bytes = [UInt8](table)
            let ascent = Int16(bitPattern: UInt16(bytes[74]) << 8 | UInt16(bytes[75]))
            let descent = Int16(bitPattern: UInt16(bytes[76]) << 8 | UInt16(bytes[77]))
            if Int(ascent) + Int(descent) != 0 { return Double(Int(ascent) + Int(descent)) / unitsPerEm }
        }
        return (CTFontGetAscent(font) + CTFontGetDescent(font)) / CTFontGetSize(font)
    }

    private static func lineHeightPerEm(_ font: CTFont) -> Double {
        (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) / CTFontGetSize(font)
    }

    /// The overlay draws the glyph background inside the caption window;
    /// libass has one box, so it takes the two composited.
    private static func boxColour(_ style: VividSubtitleRenderStyle) -> String {
        let box = style.drawsBox ? style.boxOpacity : 0
        let window = style.windowOpacity
        let alpha = box + window * (1 - box)
        guard alpha > 0 else { return colour(.black, opacity: 0) }
        func mix(_ inner: Double, _ outer: Double) -> Double { (inner * box + outer * window * (1 - box)) / alpha }
        let rgb = VividSubtitleRenderStyle.RGB(
            red: mix(style.boxColor.red, style.windowColor.red),
            green: mix(style.boxColor.green, style.windowColor.green),
            blue: mix(style.boxColor.blue, style.windowColor.blue))
        return colour(rgb, opacity: alpha)
    }

    /// mpv keeps margins as whole units of a 288-line script (2.5 of its
    /// 720-line units), dropping the fraction, so this picks the option
    /// value whose kept part is nearest.
    private static func assMargin(_ units: Double) -> Int {
        Int(((units * 0.4).rounded() * 2.5).rounded(.up))
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private static func colour(_ rgb: VividSubtitleRenderStyle.RGB, opacity: Double) -> String {
        func byte(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(opacity), byte(rgb.red), byte(rgb.green), byte(rgb.blue))
    }
}
#endif
