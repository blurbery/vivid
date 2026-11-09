#if os(tvOS) || os(iOS)
import SwiftUI

extension TVSavedAccountStore {
    /// Whether this saved profile is the one signed in right now. A
    /// signed-out profile never is.
    func isCurrent(_ account: TVSavedAccount) -> Bool {
        account.id == activeID && !account.requiresLogin && AuthService.shared.isLoggedIn
            && account.serverID == ServerRegistry.shared.activeServerId
    }

    /// The other saved profiles, in the saved order.
    var otherAccounts: [TVSavedAccount] {
        accounts.filter { !isCurrent($0) }
    }
}

/// A saved profile's picture: the server's account picture, its emoji, or
/// its first letter. The signed-in profile shows its live picture, so a
/// change on the server shows straight away.
struct SavedAccountAvatar: View {
    let account: TVSavedAccount
    let size: CGFloat
    @State private var store = TVSavedAccountStore.shared
    @State private var profileStore = CurrentProfileStore.shared

    var body: some View {
        let profile = displayedProfile
        ProfileAvatarView(avatar: profile?.avatarEmoji, imageUrl: imageURL(for: profile),
                          name: account.displayName, size: size,
                          cacheScope: profile.map {
                              VividCacheScope.key(serverID: account.serverID, accountID: account.userID,
                                                  profileID: String($0.id))
                          })
    }

    private var displayedProfile: UserProfile? {
        if store.isCurrent(account), let live = profileStore.profile,
           live.id == AuthService.shared.profileId { return live }
        return account.profile
    }

    /// A server-relative image path is joined to the profile's server.
    private func imageURL(for profile: UserProfile?) -> String? {
        guard let url = profile?.avatarImageUrl else { return nil }
        guard url.hasPrefix("/"), let server = ServerRegistry.shared.entry(with: account.serverID) else { return url }
        let base = server.url.hasSuffix("/") ? String(server.url.dropLast()) : server.url
        return base + url
    }
}

/// Up to three saved profiles' pictures overlapping from the left, the
/// first on top, each with a thin dark edge so the overlap reads.
struct SavedAccountAvatarStack: View {
    let accounts: [TVSavedAccount]
    let size: CGFloat
    var edge: Color = .black.opacity(0.6)

    private var shown: [TVSavedAccount] { Array(accounts.prefix(3)) }
    private var step: CGFloat { (size * 0.6).rounded() }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, account in
                SavedAccountAvatar(account: account, size: size)
                    .overlay(Circle().strokeBorder(edge, lineWidth: max(2, size * 0.05)))
                    .offset(x: CGFloat(index) * step)
                    .zIndex(Double(shown.count - index))
            }
        }
        .frame(width: size + CGFloat(max(shown.count - 1, 0)) * step, height: size, alignment: .leading)
        .accessibilityHidden(true)
    }
}

extension TVSavedAccount {
    /// "blur", "blur and blurbery", or "blur, blurbery and 2 more", for the
    /// Profiles row under the signed-in profile.
    static func namesSummary(_ accounts: [TVSavedAccount]) -> String {
        let names = accounts.map(\.displayName)
        switch names.count {
        case 0: return ""
        case 1...3: return ListFormatter.localizedString(byJoining: names)
        default:
            let extra = names.count - 2
            return String(localized: "\(names[0]), \(names[1]) and \(extra) more",
                          comment: "The first two saved profiles' names and how many others there are")
        }
    }
}
#endif
