#if os(iOS)
import SwiftUI

/// The server address form on iPhone and iPad. On first run Connect saves
/// the server and moves on to sign-in; in Add Server it only finds the
/// server and opens its sign-in page.
struct ServerSetupView: View {
    var router: AppRouter
    var provider: MediaServerProvider
    var addsServer: Bool

    @State private var form = ServerAddressForm()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address, port
    }

    init(router: AppRouter, provider: MediaServerProvider = .silo, addsServer: Bool = false) {
        self.router = router
        self.provider = provider
        self.addsServer = addsServer
    }

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            VividMarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)
            heading
            card
        }
        .navigationDestination(item: $form.foundServer) { server in
            LoginView(router: router, adding: server)
        }
    }

    private var heading: some View {
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
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraTextField(
                label: Text("Server address"),
                text: $form.address,
                placeholder: Text(verbatim: provider.serverPlaceholder),
                focus: $focusedField,
                equals: .address,
                contentType: .url,
                keyboard: .url,
                submitLabel: .go,
                onSubmit: connect
            )
            Label("Vivid tries secure HTTPS automatically.", systemImage: "lock.shield")
                .font(.vividCaption)
                .foregroundStyle(Color.auroraInkSecondary)
            Button {
                withAnimation(VividTheme.springAnimation) { form.showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Text("Protocol and port")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(form.showsAdvanced ? 180 : 0))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AuroraGhostButtonStyle())
            if form.showsAdvanced {
                advanced
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let message = form.message {
                AuroraErrorLabel(message)
            }
            Button(action: connect) {
                form.isBusy ? Text("Connecting…") : Text("Connect")
            }
            .buttonStyle(AuroraPrimaryButtonStyle(isLoading: form.isBusy))
            .disabled(form.isBusy)
            .padding(.top, 4)
        }
        .padding(22)
        .auroraGlass(cornerRadius: 24, emphasized: true)
        .animation(.easeInOut(duration: 0.2), value: form.message)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                AuroraFieldLabel("Protocol")
                HStack(spacing: 8) {
                    ForEach(ServerProtocolChoice.allCases, id: \.self) { choice in
                        Button {
                            form.protocolChoice = choice
                        } label: {
                            AuroraSegment(title: choice.title, isSelected: form.protocolChoice == choice, isFocused: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            AuroraTextField(
                label: Text("Port"),
                text: $form.port,
                placeholder: Text(verbatim: "8096"),
                focus: $focusedField,
                equals: .port,
                keyboard: .number
            )
        }
    }

    private func connect() {
        form.provider = provider
        if addsServer {
            form.find()
        } else {
            form.connect(router: router)
        }
    }
}
#endif
