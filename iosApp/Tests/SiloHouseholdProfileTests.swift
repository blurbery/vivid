import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Saved profiles for Silo household members must leave every existing saved
/// profile, its iCloud record and older Vivid builds exactly as they were.
final class SiloHouseholdProfileTests: XCTestCase {
    private let server = "silo-server-1"
    private let user = "7"

    private func account(_ id: String, binding: String? = nil, profileName: String? = nil, isPrimary: Bool = false) -> TVSavedAccount {
        TVSavedAccount(id: id, serverID: server, userID: user, username: "family",
                       profile: profileName.map { UserProfile(id: binding ?? "p-main", name: $0, avatarEmoji: nil, hasPin: false, isChild: false, isPrimary: isPrimary) },
                       requiresLogin: false, siloProfileID: binding)
    }

    private func envelope(_ account: TVSavedAccount) -> VividCloudAccountEnvelope {
        VividCloudAccountEnvelope(
            account: account, session: nil,
            server: ServerEntry(id: account.serverID, url: "https://example.invalid", fetchedName: "Home", lastUsedAt: .distantPast),
            pinRecord: nil, updatedAt: Date(timeIntervalSince1970: 999)
        )
    }

    private func encoded(_ vault: VividCloudAccountVault) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(vault)
    }

    // MARK: Identity

    func testExistingSavedProfileIdentityIsUnchanged() {
        // SHA-256 of "silo-server-1\0" + "7", the key every existing saved
        // profile and older build uses.
        let legacy = "fdb5ee8a4a123ac411b1f0481083f38c06466a3b03d83c673e12a9fbc0a0645c"
        XCTAssertEqual(VividCloudAccountIdentity.key(serverID: server, userID: user), legacy)
        XCTAssertEqual(VividCloudAccountIdentity.key(for: account("a")), legacy)
    }

    func testHouseholdMemberHasItsOwnIdentity() {
        let member = VividCloudAccountIdentity.key(for: account("b", binding: "p-kid"))
        XCTAssertEqual(member, "96bd44e7a9a7061a275db1c7ce3e718163785dd3eec145499c12df0cd1a88394")
        XCTAssertNotEqual(member, VividCloudAccountIdentity.key(for: account("a")))
    }

    func testSavedProfileFromAnOlderBuildDecodesUnbound() throws {
        let json = #"{"id":"a","serverID":"silo-server-1","userID":"7","username":"family","requiresLogin":false}"#
        let decoded = try JSONDecoder().decode(TVSavedAccount.self, from: Data(json.utf8))
        XCTAssertNil(decoded.siloProfileID)
        XCTAssertEqual(decoded.displayName, "family")
    }

    func testUnboundSavedProfileEncodesExactlyAsBefore() throws {
        let data = try JSONEncoder().encode(account("a", profileName: "Dad"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["siloProfileID"])
    }

    func testSiloSavedProfilesAreLabelledWithTheirProfileName() {
        XCTAssertEqual(account("a", profileName: "Dad", isPrimary: true).displayName, "Dad")
        XCTAssertEqual(account("b", binding: "p-kid", profileName: "Emma").displayName, "Emma")
    }

    func testSavedProfileWithoutItsOwnProfileNameKeepsTheUsername() {
        // An unbound card holding another member's profile, a blank name or
        // no profile yet keeps the sign-in username.
        XCTAssertEqual(account("a", profileName: "Emma").displayName, "family")
        XCTAssertEqual(account("a", profileName: "  ", isPrimary: true).displayName, "family")
        XCTAssertEqual(account("a").displayName, "family")
        // Emby and Jellyfin keep their usernames.
        let primary = UserProfile(id: "u", name: "Dad", avatarEmoji: nil, hasPin: false, isChild: false, isPrimary: true)
        for serverID in ["emby:1", "jellyfin:1"] {
            let other = TVSavedAccount(id: "e", serverID: serverID, userID: user, username: "family",
                                       profile: primary, requiresLogin: false)
            XCTAssertEqual(other.displayName, "family")
            XCTAssertNil(other.siloProfileName)
        }
    }

    // MARK: Binding

    func testPrimaryOrOnlyProfileKeepsTheOriginalIdentity() {
        let primary = UserProfile(id: "p-main", name: "Dad", avatarEmoji: nil, hasPin: false, isChild: false, isPrimary: true)
        let kid = UserProfile(id: "p-kid", name: "Emma", avatarEmoji: nil, hasPin: true, isChild: true)
        XCTAssertNil(SiloProfileBinding.binding(for: primary, profileCount: 3, serverID: server))
        XCTAssertNil(SiloProfileBinding.binding(for: kid, profileCount: 1, serverID: server))
        XCTAssertEqual(SiloProfileBinding.binding(for: kid, profileCount: 3, serverID: server), "p-kid")
        XCTAssertNil(SiloProfileBinding.binding(for: kid, profileCount: 3, serverID: "emby:" + server))
        XCTAssertNil(SiloProfileBinding.binding(for: kid, profileCount: 3, serverID: "jellyfin:" + server))
    }

    func testBoundSavedProfileOnlyCapturesItsOwnMember() {
        XCTAssertTrue(SiloProfileBinding.accepts(account("a"), profileID: "anything"))
        XCTAssertTrue(SiloProfileBinding.accepts(account("b", binding: "p-kid"), profileID: "p-kid"))
        XCTAssertFalse(SiloProfileBinding.accepts(account("b", binding: "p-kid"), profileID: "p-main"))
        XCTAssertFalse(SiloProfileBinding.accepts(account("b", binding: "p-kid"), profileID: nil))
    }

    // MARK: iCloud records

    func testOriginalRecordIsByteIdenticalWithoutHouseholdMembers() throws {
        var vault = VividCloudAccountVault()
        vault.accounts = [VividCloudAccountIdentity.key(for: account("a")): envelope(account("a", profileName: "Dad"))]
        vault.tombstones = ["gone": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 5))]
        vault.serverTombstones = ["old": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 6))]
        vault.preferences = ["accountOrder": VividCloudPreference(value: Data("[]".utf8), modifiedAt: .distantPast, writer: "w")]

        let parts = VividCloudVaultPartition.split(vault)
        XCTAssertEqual(try encoded(parts.main), try encoded(vault))
        XCTAssertTrue(parts.profiles.accounts.isEmpty)
        let recombined = VividCloudVaultPartition.combined(main: parts.main, profiles: VividCloudAccountVault())
        XCTAssertEqual(try encoded(recombined), try encoded(vault))
    }

    func testHouseholdMembersOnlyLiveInTheirOwnRecord() throws {
        let parent = account("a", profileName: "Dad")
        let kid = account("b", binding: "p-kid", profileName: "Emma")
        var vault = VividCloudAccountVault()
        vault.accounts = [VividCloudAccountIdentity.key(for: parent): envelope(parent),
                          VividCloudAccountIdentity.key(for: kid): envelope(kid)]
        vault.tombstones = ["gone": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 5))]

        let parts = VividCloudVaultPartition.split(vault)
        XCTAssertEqual(Set(parts.main.accounts.keys), [VividCloudAccountIdentity.key(for: parent)])
        XCTAssertEqual(Set(parts.profiles.accounts.keys), [VividCloudAccountIdentity.key(for: kid)])
        XCTAssertEqual(Set(parts.main.tombstones.keys), ["gone"])
        XCTAssertTrue(parts.profiles.tombstones.isEmpty)
        XCTAssertNil(parts.profiles.preferences)

        let recombined = VividCloudVaultPartition.combined(main: parts.main, profiles: parts.profiles)
        XCTAssertEqual(try encoded(recombined), try encoded(vault))
    }

    func testHouseholdRecordCannotReplaceOriginalProfiles() {
        let parent = account("a", profileName: "Dad")
        let key = VividCloudAccountIdentity.key(for: parent)
        var main = VividCloudAccountVault()
        main.accounts = [key: envelope(parent)]
        var profiles = VividCloudAccountVault()
        profiles.accounts = [key: envelope(account("x", binding: "p-kid")),
                             "stray": envelope(account("y"))]

        let combined = VividCloudVaultPartition.combined(main: main, profiles: profiles)
        XCTAssertEqual(combined.accounts[key]?.account.id, "a")
        XCTAssertNil(combined.accounts["stray"])
    }

    // MARK: Order

    func testOrderIsUnchangedWithoutHouseholdMembers() {
        let accounts = [account("a"), TVSavedAccount(id: "c", serverID: "other", userID: "1", username: "x",
                                                     profile: nil, requiresLogin: false)]
        let values = VividCloudAccountOrder.values(for: accounts)
        XCTAssertEqual(values.legacy, accounts.map { VividCloudAccountIdentity.key(for: $0) })
        XCTAssertNil(values.full)
        let reversed = Array(values.legacy.reversed())
        XCTAssertEqual(
            VividCloudAccountOrder.resolved(identities: values.legacy, legacyIdentities: Set(values.legacy),
                                            legacy: reversed, full: nil),
            VividCloudPreferencePolicy.ordered(values.legacy, preferred: reversed)
        )
    }

    func testOlderBuildsAndNewBuildsAgreeOnTheSharedOrder() {
        let parent = account("a")
        let kid = account("b", binding: "p-kid")
        let other = TVSavedAccount(id: "c", serverID: "other", userID: "1", username: "x", profile: nil, requiresLogin: false)
        let values = VividCloudAccountOrder.values(for: [parent, kid, other])
        // An older build only knows the unbound profiles and writes them in
        // this form, so neither build sees a change to rewrite.
        let olderBuild = [parent, other].map { VividCloudAccountIdentity.key(for: $0) }
        XCTAssertEqual(values.legacy, olderBuild)
        XCTAssertEqual(values.full, [parent, kid, other].map { VividCloudAccountIdentity.key(for: $0) })
    }

    func testOlderBuildRearrangementKeepsHouseholdMembersInPlace() {
        let p = VividCloudAccountIdentity.key(for: account("a"))
        let k = VividCloudAccountIdentity.key(for: account("b", binding: "p-kid"))
        let o = "other"
        let resolved = VividCloudAccountOrder.resolved(identities: [p, k, o], legacyIdentities: [p, o],
                                                       legacy: [o, p], full: [p, k, o])
        XCTAssertEqual(resolved, [o, k, p])
    }

    // MARK: Preparation

    func testMissingHouseholdProfileOffersRecoveryInsteadOfSigningOut() {
        XCTAssertFalse(LoginPreparationFailure.profileUnavailable.primaryActionSignsOut)
        XCTAssertEqual(LoginPreparationFailure.profileUnavailable.primaryTitle, "Try again")
    }
}
