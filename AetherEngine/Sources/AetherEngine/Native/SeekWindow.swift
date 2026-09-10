import Foundation

/// The stretch of a seek between the moment it is REQUESTED and the moment it is DONE (AE#491
/// round 2).
///
/// `seekGeneration` moves at the request, because everything already in flight has to be
/// invalidated there. The read position moves later: the reposition is awaited off the main actor
/// since #254, and the clock is re-anchored after that. In between, the demuxer still stands where
/// the seek came from, so a packet read there carries the OLD position's bytes under the NEW
/// generation, which is the pass condition of every gate that compares generations.
///
/// One such packet is enough, in both directions:
///
/// - Video: on a backward seek the stale frame's timestamp is PAST the target, so the skip
///   threshold lets it through and it becomes the renderer's frontier. The frontier is a maximum,
///   so no frame from the new position can lower it again and the reported cushion carries the seek
///   distance for the rest of the session (`vLead=2301.93` on a 2297 s backward jump).
/// - Audio: a packet enqueued after the landing but before the clock is re-anchored is measured
///   against the pre-seek clock, and a lead the size of the seek reads as an exhausted one, which
///   pauses the clock for a rebuffer that is not happening.
///
/// The rules below are what closes it: the loop stands still while the window is open, anything it
/// read into the window is not from the position it now serves, and only the seek that still owns
/// the window may close it.
enum SeekWindow {

    /// Open from the generation bump until that seek has landed AND re-anchored the clock.
    static func isOpen(requested: UInt64, settled: UInt64) -> Bool {
        requested != settled
    }

    /// Whether the demux loop may read at all. A seek clears `isPlaying` too, but a few statements
    /// after the bump, so the flag alone leaves both that stretch and the whole landing reachable.
    static func loopMayRead(isPlaying: Bool, windowOpen: Bool) -> Bool {
        isPlaying && !windowOpen
    }

    /// Whether a packet the loop just read describes the position the session is now on.
    ///
    /// - Parameters:
    ///   - readGeneration: the generation captured before the read. A read that started before the
    ///     bump carries the old one.
    ///   - liveGeneration: the generation now.
    ///   - windowOpen: whether a reposition is still outstanding. The reposition cannot have run
    ///     during the read, since both take the demuxer's access lock, so an open window here says
    ///     the bytes are from the position the seek left behind.
    static func admitsPacket(readGeneration: UInt64, liveGeneration: UInt64, windowOpen: Bool) -> Bool {
        readGeneration == liveGeneration && !windowOpen
    }

    /// Whether a landing may close the window. A superseded seek returns at its own guard and never
    /// asks; this is what keeps a late one from re-opening a window a newer seek has closed.
    static func closes(settling generation: UInt64, live: UInt64) -> Bool {
        generation == live
    }
}
