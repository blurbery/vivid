import Foundation

@MainActor
protocol TVPCMAudioSessionAccess: AnyObject {
    var audioRouteID: String { get }
    var audioRouteTypes: [String] { get }
    var maximumOutputNumberOfChannels: Int { get }
    var preferredOutputNumberOfChannels: Int { get }
    var outputNumberOfChannels: Int { get }
    var supportsMultichannelContent: Bool { get }
    func setSupportsMultichannelContent(_ value: Bool) throws
    func setPreferredOutputNumberOfChannels(_ count: Int) throws
}

@MainActor
final class TVPCMAudioSession {
    private struct Request: Equatable {
        let route: String
        let source: Int
        let maximum: Int
    }
    private var lastRequest: Request?
    private var originalMultichannel: Bool?
    private var appliedMultichannel: Bool?
    private var originalChannels: (route: String, count: Int)?
    private var appliedChannels: Int?
    private var lastObservation: String?

    func configure(_ session: TVPCMAudioSessionAccess, sourceChannels: Int,
                   eligible: Bool, log: (String) -> Void) {
        let hdmi = !session.audioRouteTypes.isEmpty && session.audioRouteTypes.allSatisfy { $0 == "HDMIOutput" }
        guard eligible, hdmi, sourceChannels > 0, session.maximumOutputNumberOfChannels > 0 else {
            restore(session, log: log)
            return
        }
        let request = Request(route: session.audioRouteID, source: sourceChannels,
                              maximum: session.maximumOutputNumberOfChannels)
        guard request != lastRequest else { return }
        if originalChannels?.route != request.route {
            originalChannels = nil
            appliedChannels = nil
        }
        lastRequest = request
        observe(session, sourceChannels: sourceChannels, phase: "before", log: log)
        let multichannel = sourceChannels > 2
        if session.supportsMultichannelContent != multichannel {
            let previous = session.supportsMultichannelContent
            do {
                try session.setSupportsMultichannelContent(multichannel)
                if originalMultichannel == nil { originalMultichannel = previous }
                appliedMultichannel = multichannel
            } catch { logFailure(error, operation: "declareMultichannel", log: log) }
        }
        // Re-read the route after declaring content, and never exceed its current limit.
        guard session.audioRouteID == request.route else { return }
        let count = min(sourceChannels, session.maximumOutputNumberOfChannels)
        if count > 0, session.preferredOutputNumberOfChannels != count {
            let previous = session.preferredOutputNumberOfChannels
            do {
                try session.setPreferredOutputNumberOfChannels(count)
                if originalChannels == nil { originalChannels = (request.route, previous) }
                appliedChannels = count
            } catch { logFailure(error, operation: "requestChannels", log: log) }
        }
        observe(session, sourceChannels: sourceChannels, phase: "requested", log: log)
    }

    func observe(_ session: TVPCMAudioSessionAccess, sourceChannels: Int,
                 phase: String, log: (String) -> Void) {
        let observation = "phase=\(phase) sourceChannels=\(sourceChannels) "
            + "route=\(session.audioRouteTypes.sorted().joined(separator: ",")) "
            + "maximum=\(session.maximumOutputNumberOfChannels) "
            + "preferred=\(session.preferredOutputNumberOfChannels) "
            + "actual=\(session.outputNumberOfChannels) "
            + "multichannel=\(session.supportsMultichannelContent)"
        guard observation != lastObservation else { return }
        lastObservation = observation
        log(observation)
    }

    func restore(_ session: TVPCMAudioSessionAccess, log: (String) -> Void) {
        defer {
            lastRequest = nil
            originalChannels = nil
            appliedChannels = nil
            originalMultichannel = nil
            appliedMultichannel = nil
            lastObservation = nil
        }
        if let originalChannels, originalChannels.route == session.audioRouteID,
           session.preferredOutputNumberOfChannels == appliedChannels,
           originalChannels.count > 0, originalChannels.count <= session.maximumOutputNumberOfChannels,
           originalChannels.count != session.preferredOutputNumberOfChannels {
            do { try session.setPreferredOutputNumberOfChannels(originalChannels.count) }
            catch { logFailure(error, operation: "restoreChannels", log: log) }
        }
        if let originalMultichannel, session.supportsMultichannelContent == appliedMultichannel,
           originalMultichannel != session.supportsMultichannelContent {
            do { try session.setSupportsMultichannelContent(originalMultichannel) }
            catch { logFailure(error, operation: "restoreMultichannel", log: log) }
        }
    }

    private func logFailure(_ error: Error, operation: String, log: (String) -> Void) {
        let error = error as NSError
        log("operation=\(operation) errorDomain=\(error.domain) errorCode=\(error.code)")
    }
}

#if os(tvOS)
import AVFoundation

extension AVAudioSession: TVPCMAudioSessionAccess {
    var audioRouteID: String { currentRoute.outputs.map { $0.uid }.sorted().joined(separator: "|") }
    var audioRouteTypes: [String] { currentRoute.outputs.map { $0.portType.rawValue } }
}
#endif
