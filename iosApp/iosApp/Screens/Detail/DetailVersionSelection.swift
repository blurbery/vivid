import Foundation

enum DetailVersionSelection {
    private static let autoId = "auto"

    static func displayVersion(
        versions: [FileVersion],
        selectedFileId: Int?,
        lastFileId: Int?,
        preferredQualityId: String? = nil
    ) -> FileVersion? {
        if let selectedFileId,
           let selected = versions.first(where: { $0.fileId == selectedFileId }) {
            return selected
        }

        if let lastFileId,
           let lastUsed = versions.first(where: { $0.fileId == lastFileId }) {
            return lastUsed
        }

        let preferredQuality = normalizedQualityPreference(preferredQualityId)
        return versions.max {
            score(for: $0, preferredQuality: preferredQuality)
                < score(for: $1, preferredQuality: preferredQuality)
        }
    }

    private static func normalizedQualityPreference(_ quality: String?) -> String? {
        let normalized = normalizeStoredQualityId(quality)
        return normalized == autoId ? nil : normalized
    }

    private static func normalizeStoredQualityId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch value {
        case "", autoId, "original", "2160p", "4k", "uhd":
            return autoId
        case "420p":
            return "328p"
        case "1080p-high", "1080p-medium", "1080p", "1080p-8",
             "720p-high", "720p-medium", "720p", "480p", "328p":
            return value
        default:
            return autoId
        }
    }

    private static func score(for version: FileVersion, preferredQuality: String?) -> Int {
        var score = resolutionRank(version.resolution) * 10

        if let preferredQuality {
            if qualityMatches(version.resolution, preferredQuality: preferredQuality) {
                score += 100
            } else if resolutionRank(version.resolution) > resolutionRank(preferredQuality) {
                score -= 50
            }
        }

        return score
    }

    private static func qualityMatches(_ resolution: String?, preferredQuality: String) -> Bool {
        let versionRank = resolutionRank(resolution)
        let requestedRank = resolutionRank(preferredQuality)
        return versionRank > 0 && versionRank <= requestedRank
    }

    private static func resolutionRank(_ value: String?) -> Int {
        guard let value = value?.lowercased() else { return 0 }

        if value.contains("2160") || value.contains("4k") {
            return 4
        }
        if value.contains("1080") {
            return 3
        }
        if value.contains("720") {
            return 2
        }
        if value.contains("480") {
            return 1
        }
        return 0
    }
}
