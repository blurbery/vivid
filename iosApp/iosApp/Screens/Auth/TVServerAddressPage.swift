#if os(tvOS)
import SwiftUI

/// The server address form on Apple TV. Connect saves the server and moves
/// on to sign-in.
struct TVServerSetupView: View {
    var router: AppRouter
    var prefillCurrentServer: Bool
    var provider: MediaServerProvider

    @State private var form = ServerAddressForm()
    @FocusState private var focusedTarget: Target?

    private enum Target: Hashable {
        case address, advanced, protocolChoice(ServerProtocolChoice), port, connect
    }

    init(router: AppRouter, prefillCurrentServer: Bool = false, provider: MediaServerProvider = .silo) {
        self.router = router
        self.prefillCurrentServer = prefillCurrentServer
        self.provider = provider
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VividLogoView(size: 96)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 20)
                chooser
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            VividCopyrightFooter()
                .padding(.bottom, 40)
        }
        .ignoresSafeArea()
        .onAppear(perform: prepareForm)
    }

    private var chooser: some View {
        ZStack(alignment: .top) {
            card
                .frame(width: 600, height: 580)
                .focusSection()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .defaultFocus($focusedTarget, .address, priority: .userInitiated)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Enter the server address")
                .font(.vividHeadline)
                .foregroundStyle(Color.auroraInk)
            VStack(alignment: .leading, spacing: 10) {
                TVFieldLabel(text: String(localized: "Server address"))
                AuroraInputField(
                    text: $form.address,
                    placeholder: provider.serverPlaceholder,
                    focus: $focusedTarget,
                    equals: .address,
                    isSecure: false,
                    contentType: .URL,
                    keyboard: .URL
                )
            }
            Label("Secure HTTPS is tried automatically.", systemImage: "lock.shield")
                .font(.vividCaption)
                .foregroundStyle(Color.auroraInkSecondary)
            Button {
                withAnimation(VividTheme.springAnimation) { form.showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text("Protocol and port")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(form.showsAdvanced ? 180 : 0))
                }
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focusedTarget, equals: .advanced)
            if form.showsAdvanced {
                advanced
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let message = form.message {
                TVFormMessage(text: message, wraps: true)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Button {
                form.connect(router: router)
            } label: {
                form.isBusy ? Text("Connecting…") : Text("Connect to server")
            }
            .buttonStyle(AuroraPrimaryButtonStyle(isLoading: form.isBusy))
            .focused($focusedTarget, equals: .connect)
        }
        .padding(46)
        .frame(maxHeight: .infinity, alignment: .top)
        .auroraGlass(cornerRadius: 28)
        .animation(.easeInOut(duration: 0.2), value: form.message)
        .animation(VividTheme.springAnimation, value: form.showsAdvanced)
    }

    private var advanced: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                TVFieldLabel(text: String(localized: "Protocol"))
                HStack(spacing: 8) {
                    ForEach(ServerProtocolChoice.allCases, id: \.self) { choice in
                        Button {
                            form.protocolChoice = choice
                        } label: {
                            AuroraSegment(
                                title: choice.title,
                                isSelected: form.protocolChoice == choice,
                                isFocused: focusedTarget == .protocolChoice(choice)
                            )
                        }
                        .buttonStyle(.vividFlat)
                        .focused($focusedTarget, equals: .protocolChoice(choice))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                TVFieldLabel(text: String(localized: "Port"))
                AuroraInputField(
                    text: $form.port,
                    placeholder: Self.portPlaceholder,
                    focus: $focusedTarget,
                    equals: .port,
                    isSecure: false,
                    contentType: nil,
                    keyboard: .numberPad
                )
            }
            .frame(width: 190)
        }
    }

    private static let portPlaceholder: String = "8096"

    private func prepareForm() {
        form.provider = prefillCurrentServer ? .active : provider
        if prefillCurrentServer, form.address.isEmpty {
            form.address = AuthService.shared.serverUrl
        }
        #if DEBUG
        if form.address.isEmpty,
           let value = ProcessInfo.processInfo.environment["VIVID_SETUP_SERVER_URL"],
           let url = URL(string: value), url.scheme == "https", url.host != nil {
            form.address = value
        }
        #endif
    }
}

/// An Apple TV form field's caption: uppercase, monospaced and quiet.
struct TVFieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color.auroraInkTertiary)
    }
}

/// A rose error line under an Apple TV form.
struct TVFormMessage: View {
    let text: String
    var wraps = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.requestRose)
            if wraps {
                messageText.fixedSize(horizontal: false, vertical: true)
            } else {
                messageText
            }
        }
    }

    private var messageText: some View {
        Text(text)
            .font(.vividCaption)
            .foregroundStyle(Color.requestRose)
    }
}
#endif
