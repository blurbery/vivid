import Foundation

/// The audio and subtitles playing in an Emby or Jellyfin session, as its
/// progress reports name them. Those servers show the tracks on their
/// dashboards and can remember them for the viewer's other apps, so a report
/// names the tracks actually playing rather than the ones the session
/// started with.
struct MediaServerPlayingTracks: Equatable, Sendable {
    enum Subtitle: Equatable, Sendable {
        /// No subtitles, or a file the server doesn't know (OpenSubtitles).
        case off
        /// A server subtitle file, by its stream index.
        case serverStream(Int)
        /// A subtitle stream inside the media, by its container index.
        case embedded(Int)
    }

    /// The catalogue ordinal of the playing audio, or nil when the engine's
    /// tracks don't line up with the file's (a transcode carries only the
    /// track it was asked for).
    var audioOrdinal: Int?
    /// Nil when the playing subtitle can't be named yet.
    var subtitle: Subtitle?

    /// The `AudioStreamIndex` and `SubtitleStreamIndex` a report sends.
    /// `audioStreamIndexes` maps catalogue ordinals to the server's stream
    /// indexes, as PlaybackInfo did. An embedded subtitle's container index
    /// is the server's stream index only when the file plays directly; a
    /// transcode keeps what the session asked for.
    func streamIndexes(
        audioStreamIndexes: [Int?],
        directPlay: Bool,
        initialAudio: Int?,
        initialSubtitle: Int?
    ) -> (audio: Int?, subtitle: Int) {
        let audio = audioOrdinal.flatMap { ordinal in
            audioStreamIndexes.indices.contains(ordinal) ? audioStreamIndexes[ordinal] : nil
        } ?? initialAudio
        let subtitle: Int
        switch self.subtitle {
        case .off:
            subtitle = -1
        case .serverStream(let index):
            subtitle = index
        case .embedded(let index):
            subtitle = directPlay ? index : initialSubtitle ?? -1
        case nil:
            subtitle = initialSubtitle ?? -1
        }
        return (audio, subtitle)
    }
}
