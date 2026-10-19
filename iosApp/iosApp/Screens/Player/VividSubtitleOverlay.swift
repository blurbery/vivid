
import SwiftUI

/// Presentation-only overlay for Vivid's decoded public cue model.
/// It never fetches, parses, demuxes, or selects subtitle media.
struct VividSubtitleOverlay: View {
    let engine: VividEngine
    /// Movie-timeline position. Read only while cues are loaded, so playback
    /// without subtitles never re-renders this overlay on time ticks.
    let sourceTime: () -> Double
    let primaryUsesMovieTimeline: Bool
    let secondaryUsesMovieTimeline: Bool
    let appearance: SubtitleAppearance
    let subtitleSyncMs: Int
    /// The secondary layer's own delay; an OpenSubtitles file's offset on
    /// the main subtitle doesn't apply to it.
    var secondarySubtitleSyncMs: Int? = nil

    @State private var primary: [SubtitleCue] = []
    @State private var secondary: [SubtitleCue] = []
    @State private var vividSourceTime: Double = 0

    private var renderStyle: VividSubtitleRenderStyle {
        VividSubtitleRenderStyle(appearance: appearance)
    }

    private var hasCues: Bool { !primary.isEmpty || !secondary.isEmpty }

    var body: some View {
        GeometryReader { geometry in
            if hasCues {
                let videoRect = displayedVideoRect(in: geometry.size)
                let movieTime = sourceTime()
                ZStack {
                    cueLayer(activeCues(in: primary, usesMovieTimeline: primaryUsesMovieTimeline,
                                        movieTime: movieTime, delayMs: subtitleSyncMs), videoRect: videoRect, secondary: false)
                    cueLayer(activeCues(in: secondary, usesMovieTimeline: secondaryUsesMovieTimeline,
                                        movieTime: movieTime, delayMs: secondarySubtitleSyncMs ?? subtitleSyncMs),
                             videoRect: videoRect, secondary: true)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(engine.$subtitleCues) { primary = $0; syncEngineTime() }
        .onReceive(engine.$secondarySubtitleCues) { secondary = $0; syncEngineTime() }
        .onReceive(engine.clock.$currentTime) { time in
            if hasCues { vividSourceTime = time }
        }
    }

    /// Catches the engine clock up when cues arrive after ticks were skipped.
    private func syncEngineTime() {
        if hasCues { vividSourceTime = engine.clock.currentTime }
    }

    /// Positive delay means captions appear later, so the cue clock is moved
    /// backwards. This preserves the positive-delay subtitle convention.
    static func renderClock(movieTime: Double, engineTime: Double, usesMovieTimeline: Bool, delaySeconds: Double) -> Double {
        (usesMovieTimeline ? movieTime : engineTime) - delaySeconds
    }

    private func activeCues(in cues: [SubtitleCue], usesMovieTimeline: Bool, movieTime: Double, delayMs: Int) -> [SubtitleCue] {
        // Complete sidecars use original movie timestamps; embedded cues use
        // the served stream's clock, which may be rebased by a server remux.
        let renderClock = Self.renderClock(movieTime: movieTime, engineTime: vividSourceTime,
                                          usesMovieTimeline: usesMovieTimeline, delaySeconds: Double(delayMs) / 1_000)
        return cues.filter { $0.startTime <= renderClock && renderClock < $0.endTime }
    }



    /// Text cues sharing a place on screen, shown together.
    struct CueStack: Identifiable {
        let alignment: Int?
        let cues: [SubtitleCue]
        var id: Int { alignment ?? 0 }
    }

    /// Text cues without an authored position, grouped by their alignment
    /// and stacked as libass stacks overlapping lines: the first cue keeps
    /// its place at the edge and later ones go further in, so at the bottom
    /// the latest is on top.
    static func cueStacks(_ cues: [SubtitleCue], position: VividSubtitleRenderStyle.Position) -> [CueStack] {
        let text = cues.filter { cue in
            if case .image = cue.body { return false }
            return cue.placement?.position == nil
        }
        return Dictionary(grouping: text) { $0.placement?.alignment }
            .map { alignment, group in
                let fileOrder = group.sorted { $0.id < $1.id }
                let fromTop = alignment.map { (7...9).contains($0) } ?? (position == .top)
                return CueStack(alignment: alignment, cues: fromTop ? fileOrder : fileOrder.reversed())
            }
            .sorted { ($0.alignment ?? 0) < ($1.alignment ?? 0) }
    }

    @ViewBuilder
    private func cueLayer(
        _ cues: [SubtitleCue],
        videoRect: CGRect,
        secondary: Bool
    ) -> some View {
        ForEach(cues.filter { cue in
            if case .image = cue.body { return true }
            return cue.placement?.position != nil
        }) { cue in
            switch cue.body {
            case .image(let subtitleImage):
                let rect = bitmapRect(subtitleImage, videoRect: videoRect)
                Image(decorative: subtitleImage.cgImage, scale: 1)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            case .text, .richText:
                positionedText(
                    decoratedText(cueText(cue, videoRect: videoRect), videoRect: videoRect),
                    placement: cue.placement,
                    videoRect: videoRect,
                    secondary: secondary
                )
            }
        }
        ForEach(Self.cueStacks(cues, position: renderStyle.position)) { stack in
            positionedText(
                VStack(alignment: horizontalAlignment(for: stack.alignment), spacing: 0) {
                    ForEach(stack.cues) { cue in
                        decoratedText(cueText(cue, videoRect: videoRect), videoRect: videoRect)
                    }
                },
                placement: SubtitleTextPlacement(alignment: stack.alignment),
                videoRect: videoRect,
                secondary: secondary
            )
        }
    }

    private func cueText(_ cue: SubtitleCue, videoRect: CGRect) -> Text {
        switch cue.body {
        case .text(let value):
            return styledPlainText(value, videoRect: videoRect)
        case .richText(let runs):
            return runs.reduce(Text("")) { accumulated, run in
                Text("\(accumulated)\(styledText(run, videoRect: videoRect))")
            }
        case .image:
            return Text("")
        }
    }

    private func positionedText(
        _ rendered: some View,
        placement: SubtitleTextPlacement?,
        videoRect: CGRect,
        secondary: Bool
    ) -> some View {
        Group {
            if let position = placement?.position {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: alignment(for: placement?.alignment)) {
                        rendered
                    }
                    .position(
                        x: videoRect.minX + position.x * videoRect.width,
                        y: videoRect.minY + position.y * videoRect.height
                    )
            } else {
                let resolved = defaultPlacement(
                    authoredAlignment: placement?.alignment,
                    videoRect: videoRect,
                    secondary: secondary
                )
                Color.clear
                    .overlay(alignment: resolved.alignment) {
                        rendered
                            .padding(resolved.insets)
                            .padding(.horizontal, videoRect.width * 0.04)
                    }
                    .frame(
                        width: videoRect.width,
                        height: videoRect.height
                    )
                    .position(x: videoRect.midX, y: videoRect.midY)
            }
        }
    }

    private func decoratedText(_ text: Text, videoRect: CGRect) -> some View {
        let style = renderStyle
        let scale = playfieldScale(for: videoRect)
        let edgeOffset = max(
            0.5,
            min(2, style.fontSizeAt1080Lines * 0.03) * scale
        )
        let outline = style.drawsOutline ? color(style.outlineColor) : .clear
        let raised = style.drawsRaisedEdge ? Color.white.opacity(0.8) : .clear
        let depressed = style.drawsDepressedEdge ? Color.black.opacity(0.9) : .clear
        let dropShadow = style.drawsDropShadow ? Color.black.opacity(0.85) : .clear
        let boxHorizontalPadding = style.drawsBox ? max(6, 10 * scale) : 0
        let boxVerticalPadding = style.drawsBox ? max(3, 5 * scale) : 0
        let windowHorizontalPadding = style.windowOpacity > 0 ? max(4, 6 * scale) : 0
        let windowVerticalPadding = style.windowOpacity > 0 ? max(3, 4 * scale) : 0

        return text
            .multilineTextAlignment(.center)
            .shadow(color: outline, radius: 0, x: edgeOffset, y: edgeOffset)
            .shadow(color: outline, radius: 0, x: -edgeOffset, y: edgeOffset)
            .shadow(color: outline, radius: 0, x: edgeOffset, y: -edgeOffset)
            .shadow(color: outline, radius: 0, x: -edgeOffset, y: -edgeOffset)
            .shadow(color: raised, radius: 0, x: -edgeOffset, y: -edgeOffset)
            .shadow(color: depressed, radius: 0, x: edgeOffset, y: edgeOffset)
            .shadow(
                color: dropShadow,
                radius: max(1, 3 * scale),
                x: max(0.5, 1.5 * scale),
                y: max(0.5, 2 * scale)
            )
            .padding(.horizontal, boxHorizontalPadding)
            .padding(.vertical, boxVerticalPadding)
            .background {
                if style.drawsBox {
                    RoundedRectangle(cornerRadius: max(2, 5 * scale), style: .continuous)
                        .fill(color(style.boxColor, opacity: style.boxOpacity))
                }
            }
            .padding(.horizontal, windowHorizontalPadding)
            .padding(.vertical, windowVerticalPadding)
            .background {
                if style.windowOpacity > 0 {
                    RoundedRectangle(
                        cornerRadius: style.windowCornerRadiusAt1080Lines * scale,
                        style: .continuous
                    )
                    .fill(color(style.windowColor, opacity: style.windowOpacity))
                }
            }
            .frame(maxWidth: videoRect.width * 0.86)
    }

    private struct ResolvedPlacement {
        let alignment: Alignment
        let insets: EdgeInsets
    }

    private func defaultPlacement(
        authoredAlignment: Int?,
        videoRect: CGRect,
        secondary: Bool
    ) -> ResolvedPlacement {
        if let authoredAlignment {
            let inset = videoRect.height * (secondary ? 0.17 : 0.08)
            switch authoredAlignment {
            case 7...9:
                return ResolvedPlacement(
                    alignment: alignment(for: authoredAlignment),
                    insets: EdgeInsets(top: inset, leading: 0, bottom: 0, trailing: 0)
                )
            case 1...3:
                return ResolvedPlacement(
                    alignment: alignment(for: authoredAlignment),
                    insets: EdgeInsets(top: 0, leading: 0, bottom: inset, trailing: 0)
                )
            default:
                return ResolvedPlacement(
                    alignment: alignment(for: authoredAlignment),
                    insets: EdgeInsets()
                )
            }
        }

        switch renderStyle.position {
        case .top:
            return ResolvedPlacement(
                alignment: .top,
                insets: EdgeInsets(
                    top: videoRect.height * (secondary ? 0.17 : 0.08),
                    leading: 0,
                    bottom: 0,
                    trailing: 0
                )
            )
        case .lowerThird:
            return ResolvedPlacement(
                alignment: .bottom,
                insets: EdgeInsets(
                    top: 0,
                    leading: 0,
                    bottom: videoRect.height * (secondary ? 0.36 : 0.27),
                    trailing: 0
                )
            )
        case .bottom:
            return ResolvedPlacement(
                alignment: .bottom,
                insets: EdgeInsets(
                    top: 0,
                    leading: 0,
                    bottom: videoRect.height * (secondary ? 0.17 : 0.08),
                    trailing: 0
                )
            )
        }
    }

    private func horizontalAlignment(for assAlignment: Int?) -> HorizontalAlignment {
        switch assAlignment {
        case 1, 4, 7: return .leading
        case 3, 6, 9: return .trailing
        default: return .center
        }
    }

    private func alignment(for assAlignment: Int?) -> Alignment {
        switch assAlignment {
        case 1: return .bottomLeading
        case 2: return .bottom
        case 3: return .bottomTrailing
        case 4: return .leading
        case 5: return .center
        case 6: return .trailing
        case 7: return .topLeading
        case 8: return .top
        case 9: return .topTrailing
        default: return .center
        }
    }

    /// The picture fitted to the surface at its display aspect ratio, as
    /// Lucid lays out its own subtitles. Zoom and Stretch change only the
    /// picture, so the text stays the same size and on screen.
    private func displayedVideoRect(in surfaceSize: CGSize) -> CGRect {
        Self.subtitleRect(surface: surfaceSize, picture: engine.softwareDisplaySize)
    }

    static func subtitleRect(surface: CGSize, picture: CGSize?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: surface)
        guard let picture, picture.width > 0, picture.height > 0 else { return bounds }
        let scale = min(bounds.width / picture.width, bounds.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func bitmapRect(_ image: SubtitleImage, videoRect: CGRect) -> CGRect {
        let canvasRect: CGRect
        if image.canvasSize.width > 0, image.canvasSize.height > 0 {
            let scale = videoRect.width / image.canvasSize.width
            let canvasHeight = image.canvasSize.height * scale
            canvasRect = CGRect(
                x: videoRect.minX,
                y: videoRect.midY - canvasHeight / 2,
                width: videoRect.width,
                height: canvasHeight
            )
        } else {
            canvasRect = videoRect
        }
        return CGRect(
            x: canvasRect.minX + image.position.minX * canvasRect.width,
            y: canvasRect.minY + image.position.minY * canvasRect.height,
            width: image.position.width * canvasRect.width,
            height: image.position.height * canvasRect.height
        )
    }

    private func styledPlainText(_ value: String, videoRect: CGRect) -> Text {
        Text(value)
            .font(font(renderStyle.fontFamily, size: scaledFontSize(
                renderStyle.fontSizeAt1080Lines,
                videoRect: videoRect
            )))
            .foregroundColor(color(
                renderStyle.foreground,
                opacity: renderStyle.foregroundOpacity
            ))
    }

    /// Vivid's rich runs are authored content. Each authored color/font/size
    /// wins unless MediaAccessibility marked that field as a required system
    /// override. Missing authored values still inherit Vivid’s effective style.
    private func styledText(_ run: SubtitleTextRun, videoRect: CGRect) -> Text {
        let style = renderStyle
        var text = Text(run.text)

        let hasAuthoredColor = run.color != nil
        let usesAuthoredColor = hasAuthoredColor
            && !style.contentOverrides.contains(.foregroundColor)
        let resolvedColor: VividSubtitleRenderStyle.RGB
        if usesAuthoredColor, let authored = run.color {
            resolvedColor = VividSubtitleRenderStyle.RGB(
                red: Double(authored.r) / 255,
                green: Double(authored.g) / 255,
                blue: Double(authored.b) / 255
            )
        } else {
            resolvedColor = style.foreground
        }
        let resolvedOpacity = hasAuthoredColor
            && !style.contentOverrides.contains(.foregroundOpacity)
            ? 1
            : style.foregroundOpacity
        text = text.foregroundColor(color(resolvedColor, opacity: resolvedOpacity))

        let resolvedFamily: VividSubtitleRenderStyle.FontFamily
        if let authored = run.fontName,
           !style.contentOverrides.contains(.font) {
            resolvedFamily = .custom(authored)
        } else {
            resolvedFamily = style.fontFamily
        }
        let resolvedSize = run.fontSize.map(Double.init).flatMap { authored -> Double? in
            style.contentOverrides.contains(.size) ? nil : authored
        } ?? style.fontSizeAt1080Lines
        text = text.font(font(
            resolvedFamily,
            size: scaledFontSize(resolvedSize, videoRect: videoRect)
        ))

        if run.isBold { text = text.bold() }
        if run.isItalic { text = text.italic() }
        if run.isUnderlined { text = text.underline() }
        if run.isStruckThrough { text = text.strikethrough() }
        return text
    }

    private func font(_ family: VividSubtitleRenderStyle.FontFamily, size: CGFloat) -> Font {
        switch family {
        case .sansSerif:
            return .system(size: size, weight: .semibold)
        case .serif:
            return .system(size: size, weight: .semibold, design: .serif)
        case .monospace:
            return .system(size: size, weight: .semibold, design: .monospaced)
        case .custom(let name):
            // A fixed size: subtitles follow Settings > Subtitles and the
            // video's size, not Dynamic Type.
            return .custom(name, fixedSize: size)
        }
    }

    private func scaledFontSize(_ points: Double, videoRect: CGRect) -> CGFloat {
        max(8, CGFloat(points) * playfieldScale(for: videoRect))
    }

    private func playfieldScale(for videoRect: CGRect) -> CGFloat {
        max(0.01, videoRect.height / 1_080)
    }

    private func color(
        _ rgb: VividSubtitleRenderStyle.RGB,
        opacity: Double = 1
    ) -> Color {
        Color(
            .sRGB,
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            opacity: max(0, min(1, opacity))
        )
    }
}
