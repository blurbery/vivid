import Foundation
import XCTest
@testable import Vivid

final class TVPCMAudioSessionTests: XCTestCase {
    @MainActor
    func testSurroundRequestsAreBoundedByRouteWithoutForcingFivePointOne() async {
        for (source, maximum, expected) in [(8, 8, 8), (8, 6, 6), (8, 2, 2), (6, 8, 6), (2, 8, 2), (1, 8, 1)] {
            let session = MockPCMAudioSession()
            session.maximumOutputNumberOfChannels = maximum
            let policy = TVPCMAudioSession()
            policy.configure(session, sourceChannels: source, eligible: true, log: { _ in })
            XCTAssertEqual(session.preferredOutputNumberOfChannels, expected)
            XCTAssertEqual(session.supportsMultichannelContent, source > 2)
            XCTAssertTrue(session.requests.allSatisfy { $0 > 0 && $0 <= maximum })
        }
    }

    @MainActor
    func testNativePlaybackAndOtherRoutesReceiveNoRequests() async {
        for route in [[], ["AirPlay"], ["BluetoothA2DPOutput"], ["Speaker"], ["HDMIOutput", "AirPlay"]] {
            let session = MockPCMAudioSession()
            session.audioRouteTypes = route
            TVPCMAudioSession().configure(session, sourceChannels: 8, eligible: true, log: { _ in })
            XCTAssertTrue(session.requests.isEmpty)
            XCTAssertTrue(session.declarations.isEmpty)
        }
        let session = MockPCMAudioSession()
        TVPCMAudioSession().configure(session, sourceChannels: 8, eligible: false, log: { _ in })
        XCTAssertTrue(session.requests.isEmpty)
        XCTAssertTrue(session.declarations.isEmpty)
    }

    @MainActor
    func testUnknownChannelsDoNotInventACapability() async {
        for (source, maximum) in [(0, 8), (-1, 8), (8, 0), (8, -1)] {
            let session = MockPCMAudioSession()
            session.maximumOutputNumberOfChannels = maximum
            TVPCMAudioSession().configure(session, sourceChannels: source, eligible: true, log: { _ in })
            XCTAssertTrue(session.requests.isEmpty)
            XCTAssertTrue(session.declarations.isEmpty)
        }
    }

    @MainActor
    func testRepeatedNotificationsDoNotRetryRejectedRequests() async {
        let session = MockPCMAudioSession()
        session.rejectRequests = true
        session.rejectDeclarations = true
        let policy = TVPCMAudioSession()
        var logs: [String] = []
        for _ in 0..<5 {
            policy.configure(session, sourceChannels: 8, eligible: true, log: { logs.append($0) })
        }
        XCTAssertEqual(session.requests, [8])
        XCTAssertEqual(session.declarations, [true])
        XCTAssertEqual(session.preferredOutputNumberOfChannels, 2)
        XCTAssertFalse(session.supportsMultichannelContent)
        XCTAssertTrue(logs.contains { $0.contains("operation=requestChannels") })
        XCTAssertTrue(logs.contains { $0.contains("operation=declareMultichannel") })
        XCTAssertFalse(logs.contains { $0.contains("private error text") })
    }

    @MainActor
    func testTrackChangesReconfigureAndStopRestoresOriginalPreferences() async {
        let session = MockPCMAudioSession()
        let policy = TVPCMAudioSession()
        for source in [8, 8, 6, 2, 8] {
            policy.configure(session, sourceChannels: source, eligible: true, log: { _ in })
        }
        XCTAssertEqual(session.requests, [8, 6, 2, 8])
        policy.restore(session, log: { _ in })
        XCTAssertEqual(session.preferredOutputNumberOfChannels, 2)
        XCTAssertFalse(session.supportsMultichannelContent)
        let requests = session.requests
        policy.restore(session, log: { _ in })
        XCTAssertEqual(session.requests, requests)
    }

    @MainActor
    func testSwitchingToAirPlayDoesNotApplyOldHDMIChannelPreference() async {
        let session = MockPCMAudioSession()
        session.preferredOutputNumberOfChannels = 6
        let policy = TVPCMAudioSession()
        policy.configure(session, sourceChannels: 8, eligible: true, log: { _ in })
        session.audioRouteID = "other-route"
        session.audioRouteTypes = ["AirPlay"]
        session.maximumOutputNumberOfChannels = 2
        session.preferredOutputNumberOfChannels = 2
        policy.configure(session, sourceChannels: 8, eligible: true, log: { _ in })
        XCTAssertEqual(session.requests, [8])
        XCTAssertEqual(session.preferredOutputNumberOfChannels, 2)
        XCTAssertFalse(session.supportsMultichannelContent)
    }

    @MainActor
    func testRestoreDoesNotOverwriteAnExternalPreferenceChange() async {
        let session = MockPCMAudioSession()
        let policy = TVPCMAudioSession()
        policy.configure(session, sourceChannels: 8, eligible: true, log: { _ in })
        session.preferredOutputNumberOfChannels = 6
        session.supportsMultichannelContent = false
        policy.restore(session, log: { _ in })
        XCTAssertEqual(session.preferredOutputNumberOfChannels, 6)
        XCTAssertEqual(session.requests, [8])
        XCTAssertEqual(session.declarations, [true])
    }

    @MainActor
    func testLogsDistinguishRequestedAndActualOutputWithoutDeviceIdentity() async {
        let session = MockPCMAudioSession()
        let policy = TVPCMAudioSession()
        var logs: [String] = []
        policy.configure(session, sourceChannels: 8, eligible: true, log: { logs.append($0) })
        XCTAssertTrue(logs.contains { $0.contains("preferred=8 actual=2") })
        session.outputNumberOfChannels = 6
        policy.observe(session, sourceChannels: 8, phase: "playing", log: { logs.append($0) })
        XCTAssertTrue(logs.last?.contains("actual=6") == true)
        XCTAssertFalse(logs.contains { $0.contains(session.audioRouteID) })
    }
}

@MainActor
private final class MockPCMAudioSession: TVPCMAudioSessionAccess {
    var audioRouteID = "private-device-identity"
    var audioRouteTypes = ["HDMIOutput"]
    var maximumOutputNumberOfChannels = 8
    var preferredOutputNumberOfChannels = 2
    var outputNumberOfChannels = 2
    var supportsMultichannelContent = false
    var rejectRequests = false
    var rejectDeclarations = false
    var requests: [Int] = []
    var declarations: [Bool] = []

    func setSupportsMultichannelContent(_ value: Bool) throws {
        declarations.append(value)
        if rejectDeclarations { throw rejection }
        supportsMultichannelContent = value
    }
    func setPreferredOutputNumberOfChannels(_ count: Int) throws {
        requests.append(count)
        if rejectRequests { throw rejection }
        preferredOutputNumberOfChannels = count
    }
    private var rejection: NSError {
        NSError(domain: "AudioSessionTest", code: -50,
                userInfo: [NSLocalizedDescriptionKey: "private error text"])
    }
}
