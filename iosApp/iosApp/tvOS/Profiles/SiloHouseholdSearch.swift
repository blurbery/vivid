#if os(tvOS) || os(iOS)
import SwiftUI

/// Finds the other viewing profiles on the signed-in Silo login and adds them
/// as saved profiles from a saved profile's settings. Each one added gets its
/// own session through device sign-in, approved by the signed-in session.
@Observable @MainActor
final class SiloHouseholdSearch {
    enum Phase: Equatable { case idle, searching, results, failed }

    private(set) var phase: Phase = .idle
    /// Members found that aren't saved on this device, primary first.
    private(set) var profiles: [UserProfile] = []
    private(set) var addingID: String?
    private(set) var message: String?
    var pinProfile: UserProfile?
    private var profileCount = 0
    /// A session approved for a member whose PIN is still being entered, so a
    /// mistyped PIN doesn't start another sign-in.
    private var approved: (profileID: String, accessToken: String, refreshToken: String)?

    func search(for account: TVSavedAccount) async {
        guard phase != .searching else { return }
        phase = .searching
        message = nil
        // Keep "Searching for accounts" up long enough to read.
        async let minimumDisplay: Void? = try? Task.sleep(for: .milliseconds(900))
        do {
            let all = try await AuthService.shared.getProfiles()
            _ = await minimumDisplay
            let store = TVSavedAccountStore.shared
            profileCount = all.count
            profiles = (all.filter(\.isPrimary) + all.filter { !$0.isPrimary }).filter {
                !store.hasSavedProfile($0, serverID: account.serverID, userID: account.userID, profileCount: all.count)
            }
            if profiles.isEmpty { message = "Every profile on this account is already on this device." }
            phase = .results
        } catch {
            _ = await minimumDisplay
            message = "Couldn’t search for accounts. Try again."
            phase = .failed
        }
    }

    func choose(_ profile: UserProfile, for account: TVSavedAccount) async {
        guard addingID == nil else { return }
        guard TVSavedAccountStore.shared.canAddAccount else {
            message = "You can save up to eight profiles. Delete one to add another."
            return
        }
        if profile.hasPin {
            pinProfile = profile
            return
        }
        await add(profile, pin: nil, for: account)
    }

    func add(_ profile: UserProfile, pin: String?, for account: TVSavedAccount) async {
        pinProfile = nil
        addingID = profile.id
        message = nil
        defer { addingID = nil }
        do {
            let session: (accessToken: String, refreshToken: String)
            if let approved, approved.profileID == profile.id {
                session = (approved.accessToken, approved.refreshToken)
            } else {
                discardApproved(account)
                session = try await AuthService.shared.approvedSiloSession()
                approved = (profile.id, session.accessToken, session.refreshToken)
            }
            var profileToken: String?
            if let pin {
                guard let server = ServerRegistry.shared.entry(with: account.serverID) else { throw HTTPError.serverUrlNotConfigured }
                profileToken = try await HTTPClient.shared.verifyProfilePIN(
                    serverURL: server.url, accessToken: session.accessToken, profileID: profile.id, pin: pin
                )
                guard profileToken != nil else {
                    message = "That PIN didn’t match. Try again."
                    pinProfile = profile
                    return
                }
            }
            let saved = TVSavedAccountSession(accessToken: session.accessToken, refreshToken: session.refreshToken,
                                              profile: profile, profileToken: profileToken)
            guard TVSavedAccountStore.shared.addHouseholdProfile(profile, profileCount: profileCount,
                                                                 session: saved, alongside: account) else {
                message = "Couldn’t add \(profile.name). Try again."
                discardApproved(account)
                return
            }
            approved = nil
            // On this device now, so it leaves the list.
            profiles.removeAll { $0.id == profile.id }
            message = profiles.isEmpty ? "Every profile on this account is now on this device." : nil
        } catch {
            if case HTTPError.http(let status, _) = error, status == 429 {
                message = "Too many attempts. Wait a minute, then try again."
            } else {
                message = "Couldn’t add \(profile.name). Try again."
            }
            discardApproved(account)
        }
    }

    func cancelPIN(for account: TVSavedAccount) {
        pinProfile = nil
        discardApproved(account)
    }

    /// Signs out a session approved for a member that wasn't saved.
    private func discardApproved(_ account: TVSavedAccount) {
        guard let approved else { return }
        self.approved = nil
        guard let server = ServerRegistry.shared.entry(with: account.serverID) else { return }
        Task { await HTTPClient.shared.logoutSession(serverURL: server.url, accessToken: approved.accessToken) }
    }
}

/// A household member found by Search for Accounts, in the saved-profile
/// circle style.
struct SiloHouseholdTile: View {
    let profile: UserProfile
    let account: TVSavedAccount
    let isAdding: Bool
    var avatarSize: CGFloat = 64

    var body: some View {
        VStack(spacing: avatarSize > 80 ? 14 : 8) {
            ProfileAvatarView(avatar: profile.avatarEmoji, imageUrl: profile.avatarImageUrl, name: profile.name,
                              size: avatarSize,
                              cacheScope: VividCacheScope.key(serverID: account.serverID, accountID: account.userID,
                                                              profileID: profile.id))
                .overlay {
                    if isAdding {
                        Circle().fill(.black.opacity(0.45))
                        ProgressView()
                    }
                }
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text(profile.name).lineLimit(1)
                    if profile.hasPin {
                        Image(systemName: "lock.fill").font(avatarSize > 80 ? .system(size: 15) : .caption2).opacity(0.7)
                    }
                }
                #if os(tvOS)
                .font(.system(size: 20, weight: .medium))
                #else
                .font(.subheadline.weight(.medium))
                #endif
                Text("Add")
                    #if os(tvOS)
                    .font(.system(size: 15))
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: avatarSize + 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add " + profile.name + (profile.hasPin ? ", PIN required" : ""))
    }
}
#endif
