#if os(iOS)
import SwiftUI

/// Chooses the kind of media server before its address is entered, on first
/// run and from Settings > Servers > Add Server.
struct PhoneProviderSelectionView: View {
    var router: AppRouter
    var onRestore: (() -> Void)?
    var addsServer: Bool

    init(router: AppRouter, onRestore: (() -> Void)? = nil, addsServer: Bool = false) {
        self.router = router
        self.onRestore = onRestore
        self.addsServer = addsServer
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VividLogoView(size: 140)
                Text("Please select a media server to continue.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                providerLink(.silo)
                providerLink(.emby)
                providerLink(.jellyfin)
                if let onRestore {
                    Button(action: onRestore) {
                        Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(VividAppBackdrop())
        .safeAreaInset(edge: .bottom) {
            VividCopyrightFooter()
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Color.black)
        }
    }

    private func providerLink(_ provider: MediaServerProvider) -> some View {
        NavigationLink {
            ServerSetupView(router: router, provider: provider, addsServer: addsServer)
        } label: {
            ProviderLogoCard(provider: provider)
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderLogoCard: View {
    let provider: MediaServerProvider

    private var logo: String {
        switch provider {
        case .silo: "SiloWordmark"
        case .emby: "EmbyLogo"
        case .jellyfin: "JellyfinLogo"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(height: 48)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: provider.name))
    }
}
#endif
