#if os(tvOS)
import SwiftUI

struct TVServerSetupView: View {
    var router: AppRouter
    var prefillCurrentServer = false
    var provider: MediaServerProvider = .silo

    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case advanced
        case scheme(ServerSetupScheme)
        case port
        case connect
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                connectChooser
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            VividCopyrightFooter().padding(.bottom, 40)
        }
        .ignoresSafeArea()
        .task {
            viewModel.provider = prefillCurrentServer ? MediaServerProvider.active : provider
            if prefillCurrentServer, viewModel.host.isEmpty {
                viewModel.host = AuthService.shared.serverUrl
            }
            #if DEBUG
            if viewModel.host.isEmpty,
               let setupURL = ProcessInfo.processInfo.environment["VIVID_SETUP_SERVER_URL"],
               let url = URL(string: setupURL), url.scheme == "https", url.host != nil {
                viewModel.host = setupURL
            }
            #endif
        }
    }

    private var connectChooser: some View {
        ZStack(alignment: .top) {
            manualCard
                .frame(width: 600, height: 580)
                .focusSection()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            VStack(spacing: 14) {
                Text("Connect this Apple TV")
                    .font(.vividTitle)
                    .foregroundStyle(Color.auroraInk)
                Text("Enter the server address with the remote.")
                    .font(.vividCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
            .offset(y: -24)
        }
        .frame(maxHeight: .infinity)
        .defaultFocus($focusedField, .host, priority: .userInitiated)
    }

    private var topBar: some View {
        HStack {
            VividLogoView(size: 96)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Manual entry card (active)

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Enter the server address")
                .font(.vividHeadline)
                .foregroundStyle(Color.auroraInk)

            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Server address")
                AuroraInputField(
                    text: $viewModel.host,
                    placeholder: provider == .emby ? "emby.example.com" : "silo.example.com",
                    focus: $focusedField,
                    equals: .host,
                    contentType: .URL,
                    keyboard: .URL
                )
            }

            Label("Secure HTTPS is tried automatically.", systemImage: "lock.shield")
                .font(.vividCaption)
                .foregroundStyle(Color.auroraInkSecondary)

            Button {
                withAnimation(VividTheme.springAnimation) {
                    viewModel.showsAdvancedOptions.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Protocol and port")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
                }
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focusedField, equals: .advanced)

            if viewModel.showsAdvancedOptions {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Protocol")
                        protocolSegments
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Port")
                        AuroraInputField(
                            text: $viewModel.port,
                            placeholder: "8096",
                            focus: $focusedField,
                            equals: .port,
                            keyboard: .numberPad
                        )
                    }
                    .frame(width: 190)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = viewModel.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.requestRose)
                    Text(error)
                        .font(.vividCaption)
                        .foregroundStyle(Color.requestRose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            Button {
                guard !viewModel.isLoading else { return }
                Task { await viewModel.connect(router: router) }
            } label: {
                Text(viewModel.isLoading ? "Connecting…" : "Connect to server")
            }
            .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
            .focused($focusedField, equals: .connect)
        }
        .padding(46)
        .frame(maxHeight: .infinity, alignment: .top)
        .auroraGlass(cornerRadius: 28)
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .animation(VividTheme.springAnimation, value: viewModel.showsAdvancedOptions)
    }

    private var protocolSegments: some View {
        HStack(spacing: 8) {
            ForEach(ServerSetupScheme.allCases) { scheme in
                Button {
                    viewModel.selectedScheme = scheme
                } label: {
                    AuroraSegment(
                        title: scheme.rawValue,
                        isSelected: viewModel.selectedScheme == scheme,
                        isFocused: focusedField == .scheme(scheme)
                    )
                }
                .buttonStyle(.vividFlat)
                .focused($focusedField, equals: .scheme(scheme))
            }
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color.auroraInkTertiary)
    }
}

#endif
