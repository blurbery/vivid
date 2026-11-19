import SwiftUI

/// What the player says about song identification, shared by the Apple TV
/// Song tab and the iPhone and iPad Song popover so both use one set of
/// strings.
enum SongIdentificationText {
    static var title: String {
        String(localized: "Song", comment: "Player HUD tab: identifies the song playing")
    }

    static var identify: String {
        String(localized: "Identify song", comment: "Player button: starts identifying the song playing")
    }

    static var help: String {
        String(localized: "Vivid listens to a few seconds of this scene and asks Shazam what's playing.",
               comment: "Player song identification: what Identify song does")
    }

    static var listening: String {
        String(localized: "Listening…", comment: "Player song identification: identifying the song playing")
    }

    static var stop: String {
        String(localized: "Stop", comment: "Player button: stops identifying the song playing")
    }

    static var tryAgain: String {
        String(localized: "Try again", comment: "Player button: identifies the song playing again")
    }

    static var appleMusic: String {
        String(localized: "Apple Music", comment: "Player button: opens the song found in Apple Music")
    }

    static var notFoundTitle: String {
        String(localized: "No song found", comment: "Player song identification: Shazam found no song")
    }

    static var notFoundDetail: String {
        String(localized: "Shazam didn't recognise the music. Try again when it's clearer, or louder than the dialogue.",
               comment: "Player song identification: why no song was found")
    }

    /// The Save to Shazam button's label for each save state.
    static func save(_ state: SongIdentificationModel.SaveState) -> String {
        switch state {
        case .idle:
            return String(localized: "Save to Shazam", comment: "Player button: adds the song found to the viewer's Shazam library")
        case .saving:
            return String(localized: "Saving…", comment: "Player song identification: adding the song to the Shazam library")
        case .saved:
            return String(localized: "Saved to Shazam", comment: "Player song identification: the song is in the Shazam library")
        case .failed:
            return String(localized: "Couldn't save. Try again", comment: "Player button: adding the song to the Shazam library failed; press to try again")
        }
    }

    /// Why identification failed.
    static func failure(_ failure: SongIdentificationFailure) -> String {
        switch failure {
        // The model reports a cancelled attempt as idle, never as a failure.
        case .cancelled, .unreachable:
            return String(localized: "Couldn't read this file's sound just now. Try again.",
                          comment: "Player song identification: the file's sound couldn't be fetched")
        case .unreadable:
            return String(localized: "Vivid can't read the sound in this file for song identification.",
                          comment: "Player song identification: the file's sound format isn't supported")
        case .noSound:
            return noSoundHere
        case .shazamUnavailable:
            return String(localized: "Couldn't reach Shazam. Check your connection and try again.",
                          comment: "Player song identification: Shazam couldn't be reached")
        case .timedOut:
            return String(localized: "Identifying took too long. Try again.",
                          comment: "Player song identification: identifying the song timed out")
        }
    }

    /// Why identification can't start for the item playing.
    static func unavailable(_ reason: SongIdentificationModel.Unavailability) -> String {
        switch reason {
        case .notReady:
            return String(localized: "Available once playback starts.",
                          comment: "Player song identification: waiting for playback to start")
        case .converted:
            return String(localized: "Song identification needs the original file. This stream is being converted by your server.",
                          comment: "Player song identification: unavailable while the server converts the stream")
        case .busy:
            return String(localized: "Song identification will be available once playback has settled.",
                          comment: "Player song identification: unavailable while a streamed file buffers")
        case .externalAudio:
            return String(localized: "Song identification doesn't work with an external audio track.",
                          comment: "Player song identification: unavailable with an external audio track")
        // The Song tab and button are normally hidden for an item without
        // sound, so this only shows if the engine's tracks lag behind.
        case .noSound:
            return noSoundHere
        }
    }

    private static var noSoundHere: String {
        String(localized: "There's no sound at this point in the file.",
               comment: "Player song identification: the file has no sound here")
    }
}

/// A song's square, rounded cover art, with a music note on a faint fill
/// until it loads or when Shazam has none. The grey reads on the dark
/// Apple TV HUD and on a light or dark popover alike.
struct SongArtwork: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color.gray.opacity(0.22))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Color.gray)
            if let url {
                CachedAsyncImage(
                    url: url.absoluteString,
                    targetSize: CGSize(width: size, height: size),
                    contentMode: .fill,
                    placeholderStyle: .clear
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
