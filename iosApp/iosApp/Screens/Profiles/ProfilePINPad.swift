import SwiftUI

/// A four-digit PIN pad for a profile. Completes once all four digits are in.
struct PINEntryView: View {
    private let profile: UserProfile
    private let onCancel: () -> Void
    private let onComplete: (String) -> Void

    @State private var pin = ""
    @FocusState private var focusedKey: String?

    private static let length = 4
    private static let deleteKey = "delete"

    init(profile: UserProfile, onCancel: @escaping () -> Void, onComplete: @escaping (String) -> Void) {
        self.profile = profile
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    var body: some View {
        #if os(tvOS)
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                header(avatarSize: 84)
                dots(size: 24, spacing: 24)
                numberPad
                cancelButton
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color.vividSurfaceElevated.opacity(0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
            .focusSection()
        }
        .onExitCommand {
            if pin.isEmpty { onCancel() } else { deleteDigit() }
        }
        .task {
            await Task.yield()
            focusedKey = "5"
        }
        #else
        ZStack {
            VividPageBackdrop()
            VStack(spacing: 32) {
                // Room for the sheet's drag indicator above the header.
                header(avatarSize: 64)
                    .padding(.top, 48)
                dots(size: 20, spacing: 20)
                Spacer()
                numberPad
                    .padding(.horizontal, 24)
                cancelButton
                    .padding(.bottom, 24)
            }
        }
        #endif
    }

    private func header(avatarSize: CGFloat) -> some View {
        VStack(spacing: 10) {
            ProfileAvatarView(
                avatar: profile.avatarEmoji,
                imageUrl: profile.avatarImageUrl,
                name: profile.name,
                size: avatarSize
            )
            Text("Enter PIN for \(profile.name)")
                .font(.vividSubheadline)
                .foregroundStyle(Color.vividOnSurface)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private func dots(size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<Self.length, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? Color.vividPrimary : Color.vividSurfaceVariant)
                    .frame(width: size, height: size)
            }
        }
    }

    private var numberPad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
            ForEach(1...9, id: \.self) { digit in
                digitKey(String(digit))
            }
            Color.clear
                .frame(height: KeyStyle.size)
            digitKey("0")
            Button(action: deleteDigit) {
                Image(systemName: "delete.backward")
                    .font(.system(size: KeyStyle.symbolSize, weight: .semibold))
            }
            .buttonStyle(KeyStyle())
            .modifier(KeyFocus(binding: $focusedKey, value: Self.deleteKey))
        }
        #if os(tvOS)
        .frame(width: 360)
        #endif
    }

    private func digitKey(_ digit: String) -> some View {
        Button {
            add(digit)
        } label: {
            Text(verbatim: digit)
                .font(.vividPIN)
        }
        .buttonStyle(KeyStyle())
        .modifier(KeyFocus(binding: $focusedKey, value: digit))
    }

    private var cancelButton: some View {
        Button("Cancel") {
            onCancel()
        }
        .vividTextButton()
    }

    private func add(_ digit: String) {
        guard pin.count < Self.length else { return }
        pin.append(digit)
        if pin.count == Self.length {
            onComplete(pin)
        }
    }

    private func deleteDigit() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }

    /// A round key on iPhone and iPad; a rounded square on Apple TV that
    /// fills and grows when focused.
    private struct KeyStyle: ButtonStyle {
        #if os(tvOS)
        static let size: CGFloat = 96
        static let symbolSize: CGFloat = 34
        #else
        static let size: CGFloat = 64
        static let symbolSize: CGFloat = 20
        #endif

        func makeBody(configuration: Configuration) -> some View {
            Key(configuration: configuration)
        }

        private struct Key: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .foregroundStyle(isFocused ? Color.vividBackground : Color.vividOnSurface)
                    .frame(width: KeyStyle.size, height: KeyStyle.size)
                    .background(background)
                    .overlay(border)
                    .scaleEffect(isFocused ? 1.08 : 1)
                    .opacity(configuration.isPressed ? 0.75 : 1)
                    .animation(.easeOut(duration: 0.12), value: isFocused)
            }

            @ViewBuilder
            private var background: some View {
                #if os(tvOS)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? Color.vividOnSurface : Color.white.opacity(0.1))
                #else
                Circle()
                    .fill(Color.vividSurfaceVariant)
                #endif
            }

            @ViewBuilder
            private var border: some View {
                #if os(tvOS)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused ? Color.clear : Color.white.opacity(0.18), lineWidth: 1)
                #endif
            }
        }
    }

    /// Binds a key to the pad's focus; on Apple TV it also drops the system
    /// focus effect, since the key style draws its own.
    private struct KeyFocus: ViewModifier {
        let binding: FocusState<String?>.Binding
        let value: String

        func body(content: Content) -> some View {
            #if os(tvOS)
            content
                .focused(binding, equals: value)
                .focusEffectDisabled()
            #else
            content
                .focused(binding, equals: value)
            #endif
        }
    }
}
