#if os(tvOS) || os(iOS)
import SwiftUI

extension Array {
    /// Splits profiles into rows of `size` for a centred grid.
    func profileRows(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Chooses which Silo viewing profile a new saved profile enters, when the
/// account has more than one. It uses the saved-profile selector's layout,
/// with each member's server profile picture and name.
struct SiloProfileChoiceView: View {
    let profiles: [UserProfile]
    let onChoose: (UserProfile) -> Void
    let onCancel: () -> Void
    #if os(tvOS)
    @FocusState private var focusedProfile: String?
    @Environment(\.isEnabled) private var isEnabled
    #endif

    private var subtitle: String {
        guard let name = ServerRegistry.shared.activeServer?.displayName, !name.isEmpty else {
            return "Choose the profile to add."
        }
        return "Choose the \(name) profile to add."
    }

    var body: some View {
        #if os(tvOS)
        ZStack {
            TVAppBackdrop()
            VStack(spacing: 28) {
                VividLogoView(size: 280)
                VStack(spacing: 10) {
                    Text("Who’s watching?")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                GeometryReader { viewport in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 32) {
                            ForEach(profiles) { profile in
                                Button { onChoose(profile) } label: { tile(profile, avatarSize: 108) }
                                    .buttonStyle(TVAccountCircleStyle())
                                    .focused($focusedProfile, equals: profile.id)
                            }
                        }
                        .padding(16)
                        .frame(minWidth: viewport.size.width, alignment: .center)
                    }
                    .scrollClipDisabled()
                }
                .frame(maxWidth: 1720)
                .frame(height: 190)
                .focusSection()
                Button("Cancel", action: onCancel)
                    .vividTextButton()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                VividCopyrightFooter()
                    .padding(.bottom, 40)
            }
        }
        .defaultFocus($focusedProfile, profiles.first?.id, priority: .userInitiated)
        .task(id: isEnabled) {
            // As on the saved-profile selector, the row must be enabled and
            // reach the native view tree before it takes initial focus.
            guard isEnabled else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            if focusedProfile == nil { focusedProfile = profiles.first?.id }
        }
        .onExitCommand(perform: onCancel)
        #else
        // The whole page scrolls, only when a long household can't fit.
        GeometryReader { container in
            ScrollView {
                phoneContent.frame(minHeight: container.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(VividAppBackdrop())
        #endif
    }

    #if os(iOS)
    private var phoneContent: some View {
        VStack(spacing: 28) {
            Spacer()
            VividLogoView(size: profiles.count > 4 ? 100 : 140)
            VStack(spacing: 8) {
                Text("Who’s watching?").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            cards
                .foregroundStyle(.white)
            Spacer()
            Button("Cancel", action: onCancel)
                .vividTextButton()
            VividCopyrightFooter().padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cards: some View {
        if profiles.count < 3 {
            HStack(alignment: .top, spacing: 22) {
                ForEach(profiles) { profile in
                    Button { onChoose(profile) } label: { tile(profile, avatarSize: 88).frame(width: 112) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
        } else {
            // Two across for four, like Who's watching; otherwise rows of
            // three with the last row centred.
            let columns = profiles.count == 4 ? 2 : 3
            VStack(spacing: 24) {
                ForEach(Array(profiles.profileRows(of: columns).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row) { profile in
                            Button { onChoose(profile) } label: {
                                tile(profile, avatarSize: 88).frame(width: columns == 2 ? 184 : 118)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 380)
            .padding(.horizontal, 20)
        }
    }
    #endif

    private func tile(_ profile: UserProfile, avatarSize: CGFloat) -> some View {
        VStack(spacing: avatarSize > 100 ? 14 : 12) {
            ProfileAvatarView(avatar: profile.avatarEmoji, imageUrl: profile.avatarImageUrl,
                              name: profile.name, size: avatarSize, cacheScope: cacheScope(for: profile))
            VStack(spacing: avatarSize > 100 ? 5 : 4) {
                HStack(spacing: 6) {
                    Text(profile.name).lineLimit(1)
                    if profile.hasPin {
                        Image(systemName: "lock.fill")
                            .font(avatarSize > 100 ? .system(size: 15) : .caption2)
                            .opacity(0.7)
                    }
                }
                #if os(tvOS)
                .font(.system(size: 20, weight: .medium))
                #else
                .font(.subheadline.weight(.medium))
                #endif
            }
        }
        #if os(tvOS)
        .frame(width: 142)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.name + (profile.hasPin ? ", PIN required" : ""))
    }

    private func cacheScope(for profile: UserProfile) -> String? {
        guard let server = ServerRegistry.shared.activeServerId,
              let account = VividCacheScope.accountID(for: server) else { return nil }
        return VividCacheScope.key(serverID: server, accountID: account, profileID: profile.id)
    }

}
#endif
