#if os(tvOS)
import SwiftUI

/// A title logo, or the fallback while it loads or when there is none. A
/// logo already in memory draws on the first frame.
struct TVDetailLogoTitle<Fallback: View>: View {
    let logoUrl: String?
    let label: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    var alignment: Alignment = .bottomLeading
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var url: URL? {
        let trimmed = logoUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }

    @ViewBuilder
    private var content: some View {
        if let url {
            let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
            VividLazyImage(request: VividImageRequest(url: url), transaction: Transaction(animation: animation)) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
                        .accessibilityHidden(true)
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    fallback()
                }
            }
        } else {
            fallback()
        }
    }
}

/// An episode's series logo (or name) above the episode title.
struct TVDetailHierarchyTitle: View {
    let seriesTitle: String
    let seriesLogoUrl: String?
    let episodeTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TVDetailLogoTitle(logoUrl: seriesLogoUrl, label: seriesTitle, maxWidth: 650, maxHeight: 140) {
                Text(verbatim: seriesTitle.uppercased())
                    .font(.system(size: 92, weight: .black).width(.compressed))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: episodeTitle)
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A title in condensed capitals, with a subtitle line when the title has
/// one after a colon or dash.
struct TVDetailDisplayTitle: View {
    let title: String

    var body: some View {
        let parts = Self.split(title)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: parts.main.uppercased())
                .font(.system(size: 92, weight: .black).width(.compressed))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(verbatim: subtitle.uppercased())
                    .font(.system(size: 40, weight: .heavy).width(.compressed))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .tracking(1.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func split(_ title: String) -> (main: String, subtitle: String?) {
        for separator in [": ", " \u{2014} ", " \u{2013} ", " - "] {
            guard let range = title.range(of: separator) else { continue }
            let main = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let subtitle = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !main.isEmpty, !subtitle.isEmpty {
                return (main, subtitle)
            }
        }
        return (title, nil)
    }
}

/// The small capsule above a season page's title.
struct TVDetailEyebrow: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 18, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

/// The logo that appears over the shelves once the hero has scrolled away.
struct TVDetailShelfLogo: View {
    let logoUrl: String?
    let title: String
    let isVisible: Bool

    var body: some View {
        TVDetailLogoTitle(logoUrl: logoUrl, label: title, maxWidth: 480, maxHeight: 110, alignment: .bottom) {
            Text(verbatim: title)
                .font(.system(size: 54, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
        }
        .frame(width: 480, height: 110, alignment: .bottom)
        .padding(.top, 4)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
