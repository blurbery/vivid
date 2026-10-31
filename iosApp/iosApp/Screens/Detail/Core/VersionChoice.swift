import Foundation

/// Which of a title's files the detail page shows, and so which one
/// playback starts with when nothing else is chosen.
enum DetailVersionSelection {
    /// The chosen file, else the last one played, else the best fit for the
    /// Settings quality (the earliest wins a tie).
    static func displayVersion(versions: [FileVersion], selectedFileId: Int?, lastFileId: Int?, preferredQualityId: String? = nil) -> FileVersion? {
        if let selectedFileId, let chosen = versions.first(where: { $0.fileId == selectedFileId }) {
            return chosen
        }
        if let lastFileId, let last = versions.first(where: { $0.fileId == lastFileId }) {
            return last
        }
        let preferenceTier = qualityPreference(preferredQualityId).map { resolutionTier($0) }
        var best: FileVersion?
        var bestPoints = Int.min
        for version in versions {
            let points = score(version, preferenceTier: preferenceTier)
            if points > bestPoints {
                best = version
                bestPoints = points
            }
        }
        return best
    }

    /// Settings qualities that cap the resolution. Original, Auto and the 4K
    /// names don't, and neither does anything unrecognised.
    private static let cappingQualities: Set<String> = [
        "1080p-high", "1080p-medium", "1080p", "1080p-8",
        "720p-high", "720p-medium", "720p", "480p", "328p",
    ]

    private static func qualityPreference(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "420p" { return "328p" }
        return cappingQualities.contains(value) ? value : nil
    }

    private static func resolutionTier(_ text: String?) -> Int {
        let value = (text ?? "").lowercased()
        if value.contains("2160") || value.contains("4k") { return 4 }
        if value.contains("1080") { return 3 }
        if value.contains("720") { return 2 }
        if value.contains("480") { return 1 }
        return 0
    }

    /// Ten points per resolution tier. With a quality cap, a file within it
    /// gains 100 and a file above it loses 50.
    private static func score(_ version: FileVersion, preferenceTier: Int?) -> Int {
        let tier = resolutionTier(version.resolution)
        var points = tier * 10
        if let preferenceTier {
            if tier > 0 && tier <= preferenceTier {
                points += 100
            } else if tier > preferenceTier {
                points -= 50
            }
        }
        return points
    }
}

/// Groups a title's files into editions (Theatrical, Director's Cut and so
/// on). Untagged files share the Standard edition.
enum PlaybackEditions {
    struct Edition: Identifiable, Hashable {
        /// The normalised grouping key.
        let id: String
        let label: String
        /// In server order.
        let versions: [FileVersion]
    }

    static func editions(from versions: [FileVersion]) -> [Edition] {
        var order: [String] = []
        var grouped: [String: [FileVersion]] = [:]
        for version in versions {
            let key = groupingKey(version)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(version)
        }
        return order.compactMap { key in
            guard let members = grouped[key], let first = members.first else { return nil }
            return Edition(id: key, label: displayLabel(for: first), versions: members)
        }
    }

    static func displayLabel(for version: FileVersion) -> String {
        for candidate in [version.editionRaw, version.edition] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return String(localized: "Standard")
    }

    /// The edition holding a file, if any.
    static func edition(owning fileId: Int?, in versions: [FileVersion]) -> Edition? {
        guard let fileId else { return nil }
        return editions(from: versions).first { edition in
            edition.versions.contains { $0.fileId == fileId }
        }
    }

    /// The edition key, else the English edition label, so untagged files
    /// group under "standard" in every language.
    private static func groupingKey(_ version: FileVersion) -> String {
        let key = (version.editionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? version.editionDisplayLabel.lowercased() : key
    }
}
