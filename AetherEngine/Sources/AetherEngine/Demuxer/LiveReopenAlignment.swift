import Foundation

/// Where a freshly allocated `AVIOContext` should start reading when the source behind it is a
/// live reader the engine RETAINED across a rebuild (AE#460 follow-up).
///
/// A custom live source is rebuilt on its own reader rather than reopened by URL: an option
/// correction (`reloadAtCurrentPosition(applying:)`), an audio-track switch, a background return.
/// The reader is still where the session left it, but a fresh `AVIOContext` starts its byte axis at
/// 0 regardless, so libavformat reads the host's spool from the base. Measured on
/// `aetherctl customio --live`: the playhead fell from 41.5 s to 1.9 s and the host was asked to
/// re-deliver every byte it had already delivered (15 MB, a 61 s window, at I/O speed).
///
/// Aligning the axis to the cursor makes the rebuild the edge rejoin `LiveReloadPolicy` already
/// promises on the URL branch, where a live reload is a fresh join by policy.
///
/// Pure so the rule is pinned without a container: the three inputs decide, and the caller only
/// performs the seek.
enum LiveReopenAlignment {

    enum Decision: Equatable {
        /// Read from where the context already is. A first open (cursor at 0) and every VOD open
        /// land here: VOD needs byte 0 to parse its header, and the backend seeks to the resume
        /// position afterwards.
        case readFromCurrentPosition
        /// Seek the fresh context to this byte offset before the container is opened.
        case alignTo(Int64)
        /// The source survives the rebuild but will not say where it is, so the reopen reads it
        /// from the base. Named rather than silent: on a live host that is a rewind.
        case cannotAlignReaderSilentOnPosition
    }

    /// `sourceSurvivesReopen` is what separates the two nils: a provider that opens its own
    /// transport per session (the HTTP reader) starts at 0 because there is nothing older to be at,
    /// while a retained host reader that will not report its cursor is a case worth naming.
    /// `currentSourceOffset` is an autoclosure because reading it calls into the host's reader, and
    /// every ordinary open would otherwise pay that call to reach a guard that ignores it.
    static func decision(
        isLive: Bool,
        isSeekable: Bool,
        sourceSurvivesReopen: Bool,
        currentSourceOffset: @autoclosure () -> Int64?
    ) -> Decision {
        guard isLive, isSeekable, sourceSurvivesReopen else { return .readFromCurrentPosition }
        switch currentSourceOffset() {
        case .some(let offset) where offset > 0: return .alignTo(offset)
        case .some: return .readFromCurrentPosition
        case .none: return .cannotAlignReaderSilentOnPosition
        }
    }
}
