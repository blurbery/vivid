import SwiftUI

#if os(tvOS)
struct TVProviderSelectionView: View {
    var onRestore: (() -> Void)? = nil
    var addingServer = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
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
        if addingServer {
            providerSelection.onExitCommand { dismiss() }
        } else {
            providerSelection
        }
    }

    private var providerSelection: some View {
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
                    Group {
                        if addingServer {
                            NavigationLink {
                                setupDestination(for: .silo)
                            } label: {
                                providerCard(.silo, width: cardWidth)
                            }
                        } else {
                            NavigationLink(value: Route.serverSetup) {
                                providerCard(.silo, width: cardWidth)
                            }
                        }
                    }
                    .buttonStyle(.card)
                    .focused($focusedProvider, equals: .silo)
                    .accessibilityHint("Connect to your Silo server")

                    NavigationLink {
                        setupDestination(for: .emby)
                    } label: {
                        providerCard(.emby, width: cardWidth)
                    }
                    .buttonStyle(.card)
                    .focused($focusedProvider, equals: .emby)
                    .accessibilityHint("Connect to your Emby server")
                    NavigationLink {
                        setupDestination(for: .jellyfin)
                    } label: {
                        providerCard(.jellyfin, width: cardWidth)
                    }
                    .buttonStyle(.card)
                    .focused($focusedProvider, equals: .jellyfin)
                    .accessibilityHint("Connect to your Jellyfin server")
                }
            }
            .overlay(alignment: .bottom) {
                if !addingServer, let onRestore {
                    Button(action: onRestore) {
                        Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                            .font(.system(size: 24, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .offset(y: 100)
                }
            }
            .position(
                x: geometry.size.width / 2,
                y: geometry.size.height / 2 - (headerHeight + spacing) / 2
            )
        }
        .defaultFocus($focusedProvider, .silo)
        .overlay(alignment: .bottom) {
            VividCopyrightFooter()
                .padding(.bottom, 40)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func setupDestination(for provider: MediaServerProvider) -> some View {
        if addingServer {
            TVSavedAccountEditor(accountID: nil, addingServer: true, selectedServerProvider: provider)
        } else {
            TVServerSetupView(router: router, provider: provider)
        }
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

#if os(iOS) || os(tvOS)
/// Restoration is optional and never owns the server-selection navigation.
struct TVCloudRestoreView: View {
    let onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0
    @State private var message: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Restore from iCloud")
                .font(.title2.bold())
            if let message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Checking for saved accounts…")
            }
            HStack(spacing: 24) {
                Button("Back") { dismiss() }
                if message != nil {
                    Button("Try Again") { attempt += 1 }
                }
            }
            .buttonStyle(.bordered)
        }
        #if os(tvOS)
        .padding(60)
        #else
        .padding(24)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
        .task(id: attempt) {
            message = nil
            // No router is supplied: backing out must not let this request
            // navigate away from manual setup when it eventually completes.
            await VividCloudAccountSync.shared.synchronize()
            guard !Task.isCancelled else { return }
            if !TVSavedAccountStore.shared.accounts.isEmpty {
                onRestored()
            } else if VividCloudAccountSync.shared.bootstrapFailed {
                message = "Couldn’t restore from iCloud. Try again, or go back to set up your server manually."
            } else {
                message = "No saved accounts are available from iCloud. Go back to set up your server manually."
            }
        }
    }
}
#endif
