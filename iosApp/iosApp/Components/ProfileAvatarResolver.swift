import Foundation

/// Resolves server image URLs for profile cards and account avatars.
enum ProfileAvatarResolver {
    /// Resolve the server-supplied `avatar_url`. Absolute URLs (presigned
    /// upload URLs) are used verbatim; a server-relative path is
    /// prefixed with the active server URL. Returns nil when absent or when
    /// no active server is known for a relative path.
    static func serverResolvedImageURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()

        // The image pipeline has no SVG decoder. Decline SVG URLs so the
        // caller can use another server image or its initials fallback.
        let pathOnly = lowercased.split(separator: "?", maxSplits: 1)[0]
        if pathOnly.hasSuffix(".svg") || pathOnly.hasSuffix("/svg") { return nil }

        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("file://") {
            return trimmed
        }

        guard trimmed.hasPrefix("/") else { return nil }
        let serverURL = ServerRegistry.shared.activeServerUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !serverURL.isEmpty else { return nil }
        return serverURL + trimmed
    }

    static func isImage(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("preset:") else { return false }
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("content://")
            || lowercased.hasPrefix("file://")
            || lowercased.hasPrefix("/")
            || lowercased.contains("/")
            || lowercased.contains(".png")
            || lowercased.contains(".jpg")
            || lowercased.contains(".jpeg")
            || lowercased.contains(".webp")
            || lowercased.contains(".gif")
            || lowercased.contains(".svg")
            || lowercased.contains(".avif")
    }

    static func imageURL(for value: String) -> String? {
        guard !value.lowercased().hasPrefix("preset:") else { return nil }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("content://")
            || lowercased.hasPrefix("file://") {
            return value
        }

        if value.hasPrefix("/") || value.contains("/") {
            let serverURL = ServerRegistry.shared.activeServerUrl
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !serverURL.isEmpty else { return nil }
            if value.hasPrefix("/") { return serverURL + value }
            return serverURL + "/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return value
    }
}
