import Foundation

/// Display labels for the shared extras/videos kind vocabulary.
///
/// Ported from the web client's `web/src/lib/extraKinds.ts` so all three
/// clients name a kind identically. Keep in sync with the server's kind
/// list; unknown kinds degrade to the generic label rather than showing a
/// raw identifier like `behind_the_scenes` to a viewer.
enum ExtraKindLabels {
    /// Singular label for one card (`extraKindLabel` on web).
    static func label(for kind: String) -> String {
        switch kind {
        case "trailer": String(localized: "Trailer")
        case "teaser": String(localized: "Teaser")
        case "featurette": String(localized: "Featurette")
        case "clip": String(localized: "Clip")
        case "behind_the_scenes": String(localized: "Behind the Scenes")
        case "bloopers": String(localized: "Bloopers")
        case "deleted_scene": String(localized: "Deleted Scene")
        default: String(localized: "Extra")
        }
    }

}
