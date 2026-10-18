#if os(tvOS)
import SwiftUI

struct TVTMDbSettingsView: View {
    @State private var store = TVTMDbStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                HStack(spacing: TVSettingsLayout.scaled(20)) {
                    Image(systemName: "film.stack")
                        .font(.tvSettings(27, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: TVSettingsLayout.scaled(62), height: TVSettingsLayout.scaled(62))
                        .background(TVSettingsPalette.iconFill,
                                    in: RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(15.5)))
                    VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(7)) {
                        Text("TMDb")
                            .font(.tvSettings(40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Trailers, TMDB ratings, collections and Studios & Networks come from TMDB through Vivid. There’s nothing to set up.")
                            .font(.tvSettings(20)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.bottom, TVSettingsLayout.scaled(18))
                TVSettingsSectionHeader("TMDB CONNECTION")
                TVSettingsGroup {
                    TVSettingsInfoRow(title: "Status", value: store.isConfigured ? "Connected" : "Not available", showsConnectedDot: store.isConfigured)
                }
                TVSettingsFooter("Trailers open in the YouTube app, which must be installed on your Apple TV.")
                TVSettingsSectionHeader("ABOUT TMDB")
                TVTMDbAttribution()
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(24)).padding(.top, TVSettingsLayout.scaled(48)).padding(.bottom, TVSettingsLayout.scaled(64))
            .frame(maxWidth: .infinity)
        }
        .background(SettingsBackdrop())
    }
}

struct TVTMDbAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(16)) {
            Image("TMDbAttributionLogo").resizable().scaledToFit()
                .frame(width: TVSettingsLayout.scaled(140), height: TVSettingsLayout.scaled(54)).accessibilityLabel("TMDB")
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.tvSettings(19)).foregroundStyle(.secondary)
            Text("themoviedb.org").font(.tvSettings(19)).foregroundStyle(.secondary)
        }.padding(TVSettingsLayout.scaled(24))
    }
}
#endif
