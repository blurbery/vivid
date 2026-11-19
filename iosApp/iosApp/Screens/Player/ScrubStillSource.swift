import CoreGraphics

/// A reader the scrub preview provider can ask for a still from the stream
/// itself, when the server has no preview sheets for it.
@MainActor
protocol ScrubStillSource: AnyObject {
    /// The frame at `transportTime`, on the loaded transport's own clock, no
    /// wider than `maxWidth`. Nil when there is none.
    func thumbnail(at transportTime: Double, maxWidth: Int) async -> CGImage?
    func shutdown() async
    /// False once the reader knows it can't take stills from this stream at
    /// all, so a nil still is not worth asking for again.
    func canProduceStills() async -> Bool
}
