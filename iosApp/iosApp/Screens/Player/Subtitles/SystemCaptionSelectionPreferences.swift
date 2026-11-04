import Foundation
import MediaAccessibility

/// The non-visual half of Apple's Subtitles & Captioning settings: when to
/// show subtitles and in which languages. Read only; the system profile is
/// the source of truth and Vivid never writes it.
struct SystemCaptionSelectionPreferences: Equatable {
    enum DisplayMode: Equatable {
        case forcedOnly
        case automatic
        case alwaysOn
    }

    var displayMode: DisplayMode
    /// Ordered canonical language identifiers from the active Apple profile.
    var preferredLanguages: [String]
    /// True when Apple asks players to prefer CC/SDH accessibility tracks.
    var prefersAccessibilityTracks: Bool
    /// The device's languages (`Locale.preferredLanguages`). Apple's
    /// Automatic compares the audio with, and shows subtitles in, the first
    /// of these rather than the caption languages above.
    var deviceLanguages: [String] = []

    static func current() -> SystemCaptionSelectionPreferences {
        let displayMode: DisplayMode
        switch MACaptionAppearanceGetDisplayType(.user) {
        case .forcedOnly:
            displayMode = .forcedOnly
        case .alwaysOn:
            displayMode = .alwaysOn
        case .automatic:
            displayMode = .automatic
        @unknown default:
            displayMode = .automatic
        }

        let selectedLanguages = MACaptionAppearanceCopySelectedLanguages(.user)
            .takeRetainedValue() as? [String] ?? []
        let languages = selectedLanguages.isEmpty ? Locale.preferredLanguages : selectedLanguages
        let characteristics = MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(.user)
            .takeRetainedValue() as? [String] ?? []
        let accessibilityCharacteristics = Set([
            MAMediaCharacteristicDescribesMusicAndSoundForAccessibility as String,
            MAMediaCharacteristicTranscribesSpokenDialogForAccessibility as String,
        ])

        return SystemCaptionSelectionPreferences(
            displayMode: displayMode,
            preferredLanguages: languages,
            prefersAccessibilityTracks: !accessibilityCharacteristics.isDisjoint(with: characteristics),
            deviceLanguages: Locale.preferredLanguages
        )
    }
}
