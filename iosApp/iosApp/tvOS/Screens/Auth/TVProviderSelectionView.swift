#if os(tvOS)
import SwiftUI

struct TVProviderSelectionView: View {
    @Environment(AppRouter.self) private var router
    @FocusState private var focusedProvider: Provider?

    private enum Provider: String {
        case silo = "Silo"
        case emby = "Emby"
        case jellyfin = "Jellyfin"

        var imageName: String {
            switch self {
            case .silo: "SiloWordmark"
            case .emby: "EmbyLogo"
            case .jellyfin: "JellyfinLogo"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing = VividTheme.padding
            let cardWidth = min(
                (geometry.size.width - 2 * VividTheme.safePadding - 2 * spacing) / 3,
                488
            )
            let logoSize: CGFloat = 220
            let instructionHeight: CGFloat = 36
            let headerHeight = logoSize + VividTheme.smallPadding + instructionHeight

            VStack(spacing: spacing) {
                VStack(spacing: VividTheme.smallPadding) {
                    VividLogoView(size: logoSize)

                    Text("Please select a media server to continue.")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(height: instructionHeight)
                }

                HStack(spacing: spacing) {
                    NavigationLink(value: Route.serverSetup) {
                        providerCard(.silo, width: cardWidth)
                    }
                    .buttonStyle(.card)
                    .focused($focusedProvider, equals: .silo)
                    .accessibilityHint("Connect to your Silo server")

                    NavigationLink {
                        TVServerSetupView(router: router, provider: .emby)
                    } label: {
                        providerCard(.emby, width: cardWidth)
                    }
                    .buttonStyle(.card)
                    .focused($focusedProvider, equals: .emby)
                    .accessibilityHint("Connect to your Emby server")
                    comingSoonCard(.jellyfin, width: cardWidth)
                }
            }
            .position(
                x: geometry.size.width / 2,
                y: geometry.size.height / 2 - (headerHeight + spacing) / 2
            )
        }
        .defaultFocus($focusedProvider, .silo)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            VividCopyrightFooter()
                .padding(.bottom, 40)
        }
        .ignoresSafeArea()
    }

    private func comingSoonCard(_ provider: Provider, width: CGFloat) -> some View {
        Button {} label: {
            providerCard(provider, width: width)
        }
        .buttonStyle(.card)
        .focused($focusedProvider, equals: provider)
        .accessibilityHint("\(provider.rawValue) support is coming soon")
    }

    private func providerCard(
        _ provider: Provider,
        width: CGFloat
    ) -> some View {
        VStack(spacing: VividTheme.smallPadding) {
            Image(provider.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: width * 0.58, height: 100)
                .accessibilityLabel(provider.rawValue)

            if provider == .jellyfin {
                Text("Coming soon")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: width, height: width / VividTheme.backdropAspectRatio)
        .background(
            Color(red: 17 / 255, green: 18 / 255, blue: 20 / 255),
            in: RoundedRectangle(cornerRadius: VividTheme.cardCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VividTheme.cardCornerRadius)
                .strokeBorder(focusedProvider == provider ? Color.white : .clear, lineWidth: 3)
        }
    }
}
#endif
