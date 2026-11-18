import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

final class ThemeMusicCenterTests: XCTestCase {
    private func key(
        profile: String = "profile-a",
        server: String = "server-a",
        owner: String = "series-1",
        song: String = "song-1"
    ) -> ThemeMusicKey {
        ThemeMusicKey(provider: "silo", serverID: server, profileID: profile, ownerID: owner, songID: song)
    }

    private let allowed = ThemeMusicPolicy.Conditions(
        isEnabled: true,
        isPictureInPictureEngaged: false,
        isOtherAudioPlaying: false,
        isServerReachable: true,
        isVideoPlayerOnScreen: false,
        isAppActive: true
    )

    // MARK: Same song

    func testTheSongAlreadyPlayingCarriesOn() {
        XCTAssertEqual(ThemeMusicPolicy.decision(for: key(), playing: key(), finished: nil), .keepPlaying)
    }

    func testAFinishedSongStaysQuietForTheSameKey() {
        XCTAssertEqual(ThemeMusicPolicy.decision(for: key(), playing: nil, finished: key()), .stayQuiet)
    }

    func testADifferentSongPlays() {
        XCTAssertEqual(
            ThemeMusicPolicy.decision(for: key(owner: "movie-2", song: "song-2"), playing: key(), finished: key()),
            .play
        )
    }

    func testAnotherProfileOrServerNeverReusesState() {
        XCTAssertEqual(ThemeMusicPolicy.decision(for: key(profile: "profile-b"), playing: key(), finished: nil), .play)
        XCTAssertEqual(ThemeMusicPolicy.decision(for: key(server: "server-b"), playing: nil, finished: key()), .play)
    }

    // MARK: Starting

    func testStartsWhenEverythingAllows() {
        XCTAssertTrue(ThemeMusicPolicy.canStart(allowed))
    }

    func testEachBlockerStopsAStart() {
        var conditions = allowed
        conditions.isEnabled = false
        XCTAssertFalse(ThemeMusicPolicy.canStart(conditions))

        conditions = allowed
        conditions.isPictureInPictureEngaged = true
        XCTAssertFalse(ThemeMusicPolicy.canStart(conditions))

        conditions = allowed
        conditions.isOtherAudioPlaying = true
        XCTAssertFalse(ThemeMusicPolicy.canStart(conditions))

        conditions = allowed
        conditions.isServerReachable = false
        XCTAssertFalse(ThemeMusicPolicy.canStart(conditions))

        conditions = allowed
        conditions.isVideoPlayerOnScreen = true
        XCTAssertFalse(ThemeMusicPolicy.canStart(conditions))

        conditions = allowed
        conditions.isAppActive = false
        XCTAssertFalse(ThemeMusicPolicy.canStart(conditions))
    }

    // MARK: Lookups

    func testAFailedLookupLeavesTheCurrentSongAlone() {
        XCTAssertEqual(ThemeMusicPolicy.outcome(of: .failed), .leaveAlone)
    }

    func testATitleWithNoThemeStopsTheSong() {
        XCTAssertEqual(ThemeMusicPolicy.outcome(of: .none), .stop)
    }

    func testAFoundThemeIsConsidered() {
        let lookup = ThemeSongLookup(ownerID: "series-1", songID: "song-1", container: "mp3")
        XCTAssertEqual(ThemeMusicPolicy.outcome(of: .found(lookup)), .consider(lookup))
    }

    func testSeasonsAndEpisodesInheritWhateverTheCase() {
        for type in ["season", "Season", "EPISODE", " Episode "] {
            XCTAssertTrue(ThemeMusicItem(contentID: "1", type: type, seriesID: "s").inheritsFromParent, type)
        }
        for type in ["movie", "Series", "seasons", ""] {
            XCTAssertFalse(ThemeMusicItem(contentID: "1", type: type, seriesID: nil).inheritsFromParent, type)
        }
    }

    // MARK: Retrying

    func testAnUnreachableServerEarnsARetry() {
        var conditions = allowed
        conditions.isServerReachable = false
        XCTAssertTrue(ThemeMusicPolicy.shouldRetryWhenReachable(conditions))

        // Still worth it while the app is inactive: becoming active retries next.
        conditions.isAppActive = false
        XCTAssertTrue(ThemeMusicPolicy.shouldRetryWhenReachable(conditions))
    }

    func testDeliberateSkipsNeverRetryWhenTheServerReturns() {
        XCTAssertFalse(ThemeMusicPolicy.shouldRetryWhenReachable(allowed))

        var conditions = allowed
        conditions.isServerReachable = false
        conditions.isOtherAudioPlaying = true
        XCTAssertFalse(ThemeMusicPolicy.shouldRetryWhenReachable(conditions))

        conditions = allowed
        conditions.isServerReachable = false
        conditions.isPictureInPictureEngaged = true
        XCTAssertFalse(ThemeMusicPolicy.shouldRetryWhenReachable(conditions))

        conditions = allowed
        conditions.isServerReachable = false
        conditions.isVideoPlayerOnScreen = true
        XCTAssertFalse(ThemeMusicPolicy.shouldRetryWhenReachable(conditions))

        conditions = allowed
        conditions.isServerReachable = false
        conditions.isEnabled = false
        XCTAssertFalse(ThemeMusicPolicy.shouldRetryWhenReachable(conditions))
    }

    // MARK: Volume

    func testVolumeFollowsThePercentWithinItsRange() {
        XCTAssertEqual(ThemeMusicPolicy.targetVolume(percent: 30), 0.3, accuracy: 0.0001)
        XCTAssertEqual(ThemeMusicPolicy.targetVolume(percent: 0), 0.05, accuracy: 0.0001)
        XCTAssertEqual(ThemeMusicPolicy.targetVolume(percent: 250), 1, accuracy: 0.0001)
    }
}
