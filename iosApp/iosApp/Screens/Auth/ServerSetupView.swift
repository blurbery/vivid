import SwiftUI

#if !os(tvOS)
struct ServerSetupView: View {
    var router: AppRouter
    var provider: MediaServerProvider = .silo
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case host, port }

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            VividMarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

            VStack(spacing: 10) {
                Text("Connect to your server")
                    .font(.vividTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text("Enter the address you use to open \(provider.name) in a browser.")
                    .font(.vividBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                AuroraTextField(
                    label: "Server address",
                    text: $viewModel.host,
                    placeholder: provider == .emby ? "emby.example.com" : "silo.example.com",
                    focus: $focusedField,
                    equals: .host,
                    contentType: .url,
                    keyboard: .url,
                    submitLabel: .go,
                    onSubmit: { connect() }
                )

                Label("Vivid tries secure HTTPS automatically.", systemImage: "lock.shield")
                    .font(.vividCaption)
                    .foregroundStyle(Color.auroraInkSecondary)

                advancedDisclosure

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    connect()
                } label: {
                    Text(viewModel.isLoading ? "Connecting…" : "Connect")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
                .disabled(viewModel.isLoading)
                .padding(.top, 4)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
    }

    private func connect() {
        viewModel.provider = provider
        guard !viewModel.isLoading else { return }
        Task { await viewModel.connect(router: router) }
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        Button {
            withAnimation(VividTheme.springAnimation) {
                viewModel.showsAdvancedOptions.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Text("Protocol and port")
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuroraGhostButtonStyle())

        if viewModel.showsAdvancedOptions {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    AuroraFieldLabel("Protocol")
                    HStack(spacing: 8) {
                        ForEach(ServerSetupScheme.allCases) { scheme in
                            Button {
                                viewModel.selectedScheme = scheme
                            } label: {
                                AuroraSegment(
                                    title: scheme.rawValue,
                                    isSelected: viewModel.selectedScheme == scheme,
                                    isFocused: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                AuroraTextField(
                    label: "Port",
                    text: $viewModel.port,
                    placeholder: "8096",
                    focus: $focusedField,
                    equals: .port,
                    keyboard: .number
                )
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
#endif

#if os(iOS)
struct PhoneProviderSelectionView: View {
    var router: AppRouter
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VividLogoView(size: 140)
                Text("Please select a media server to continue.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                NavigationLink(value: Route.serverSetup) {
                    providerCard("Silo", image: "SiloWordmark", available: true)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    ServerSetupView(router: router, provider: .emby)
                } label: {
                    providerCard("Emby", image: "EmbyLogo", available: true)
                }.buttonStyle(.plain)
                providerCard("Jellyfin", image: "JellyfinLogo", available: false)
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VividCopyrightFooter().padding(.vertical, 16).frame(maxWidth: .infinity).background(.black)
        }
    }

    private func providerCard(_ name: String, image: String, available: Bool) -> some View {
        VStack(spacing: 12) {
            Image(image).resizable().scaledToFit().frame(height: 48)
            if !available {
                Text("Coming soon").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(available ? name : "\(name), coming soon")
    }
}
#endif
