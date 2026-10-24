#if os(iOS)
import SwiftUI

/// Web-style Settings destination row with a descriptive second line and an
/// optional current value. The containing NavigationLink or Button owns the
/// interaction so the full row remains a native 44-point target.
struct SettingsOverviewRow: View {
    private let title: Text
    private let subtitle: Text
    let systemImage: String
    var tint: Color = .vividAccent
    var value: String? = nil
    var showsChevron = true

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String,
         tint: Color = .vividAccent, value: String? = nil, showsChevron: Bool = true) {
        self.init(title: Text(title), subtitle: Text(subtitle), systemImage: systemImage,
                  tint: tint, value: value, showsChevron: showsChevron)
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<T: StringProtocol, S: StringProtocol>(title: T, subtitle: S, systemImage: String,
                                               tint: Color = .vividAccent, value: String? = nil, showsChevron: Bool = true) {
        self.init(title: Text(title), subtitle: Text(subtitle), systemImage: systemImage,
                  tint: tint, value: value, showsChevron: showsChevron)
    }

    private init(title: Text, subtitle: Text, systemImage: String, tint: Color, value: String?, showsChevron: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.value = value
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 13) {
            Group {
                if systemImage == "SeerrSettingsIcon" || systemImage == "AboutInfoIcon" {
                    Image(systemImage).renderingMode(.template).resizable().scaledToFit().padding(8)
                } else { Image(systemName: systemImage) }
            }
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Color(red: 0.12, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.headline)
                    .foregroundStyle(Color.vividOnSurface)

                subtitle
                    .font(.footnote)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .bold()
                    .foregroundStyle(Color.vividSecondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
