import SwiftUI

struct ServiceAcknowledgementsView: View {
    private struct Credit: Identifiable {
        let name: String
        let image: String
        let thanks: String
        let website: String
        var id: String { name }
    }

    private let credits: [Credit] = [
        Credit(name: "AetherEngine", image: "AcknowledgementAether",
               thanks: "Thank you for powering playback on Apple TV.",
               website: "aetherengine.superuser404.de"),
        Credit(name: "IntroDB", image: "AcknowledgementIntroDB",
               thanks: "Thank you for community intro and credits timestamps.",
               website: "introdb.app"),
        Credit(name: "TheIntroDB", image: "AcknowledgementTheIntroDB",
               thanks: "Thank you for helping more episodes offer skip prompts.",
               website: "theintrodb.org"),
        Credit(name: "TMDB", image: "TMDbAttributionLogo",
               thanks: "Thank you for the movie and TV metadata and artwork. This product uses the TMDB API but is not endorsed or certified by TMDB.",
               website: "themoviedb.org")
    ]

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]
        #else
        [GridItem(.adaptive(minimum: 280), spacing: 20)]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: pageSpacing) {
                Text("Acknowledgements")
                    #if os(tvOS)
                    .font(.system(size: 42, weight: .bold))
                    #else
                    .font(.largeTitle.bold())
                    #endif
                Text("With thanks to the projects and communities that help make Vivid possible.")
                    #if os(tvOS)
                    .font(.system(size: 20))
                    #else
                    .font(.body)
                    #endif
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: pageSpacing) {
                    ForEach(credits) { credit in
                        creditCard(credit)
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            #if os(tvOS)
            .frame(maxWidth: TVSettingsLayout.contentWidth)
            .padding(20)
            #else
            .padding(32)
            .frame(maxWidth: 1160)
            #endif
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .settingsNavigationChrome()
        #endif
    }

    private var pageSpacing: CGFloat {
        #if os(tvOS)
        16
        #else
        28
        #endif
    }
    private var cardSpacing: CGFloat {
        #if os(tvOS)
        10
        #else
        14
        #endif
    }
    private var cardPadding: CGFloat {
        #if os(tvOS)
        16
        #else
        24
        #endif
    }

    private func creditCard(_ credit: Credit) -> some View {
        VStack(spacing: cardSpacing) {
            Image(credit.image)
                .resizable()
                .scaledToFit()
                #if os(tvOS)
                .frame(width: 120, height: 56)
                #else
                .frame(width: 120, height: 80)
                #endif
                .accessibilityHidden(true)
            Text(credit.name)
                #if os(tvOS)
                .font(.system(size: 26, weight: .bold))
                #else
                .font(.title3.bold())
                #endif
            Text(credit.thanks)
                #if os(tvOS)
                .font(.system(size: 19))
                .frame(height: 114, alignment: .top)
                #else
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                #endif
                .foregroundStyle(.secondary)
            Text(credit.website)
                #if os(tvOS)
                .font(.system(size: 17))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                #else
                .font(.footnote)
                #endif
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(cardPadding)
        #if os(tvOS)
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        #else
        .frame(maxWidth: .infinity, minHeight: 270)
        #endif
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        #if os(tvOS)
        .focusable()
        #endif
    }
}
