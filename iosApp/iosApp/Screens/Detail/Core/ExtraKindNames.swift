import Foundation

/// Display names for the kinds of extra a title can have (trailers, clips,
/// featurettes and so on). Kinds are matched exactly; anything unknown reads
/// "Extra".
enum ExtraKindLabels {
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
