import SwiftUI

/// A round profile picture: the profile's image once it has loaded, and an
/// emoji, initial or person symbol before that or when there is none.
struct ProfileAvatarView: View {
    let avatar: String?
    var imageUrl: String?
    let name: String
    let size: CGFloat
    var backgroundColor: Color
    var textColor: Color
    var cacheScope: String?

    /// The URL of the last image that appeared.
    @State private var shownURL: String?

    init(
        avatar: String?,
        imageUrl: String? = nil,
        name: String,
        size: CGFloat,
        backgroundColor: Color = .vividSurfaceVariant,
        textColor: Color = .vividOnSurface,
        cacheScope: String? = nil
    ) {
        self.avatar = avatar
        self.imageUrl = imageUrl
        self.name = name
        self.size = size
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.cacheScope = cacheScope
    }

    private var trimmedAvatar: String {
        avatar?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var resolvedImageURL: String? {
        if let url = ProfileAvatarResolver.serverResolvedImageURL(imageUrl) { return url }
        let value = trimmedAvatar
        guard !value.isEmpty, ProfileAvatarResolver.isImage(value) else { return nil }
        return ProfileAvatarResolver.imageURL(for: value)
    }

    /// An emoji or short text chosen as the avatar.
    private var textAvatar: String? {
        let value = trimmedAvatar
        let lowered = value.lowercased()
        guard !value.isEmpty,
              !lowered.hasPrefix("upload:"),
              !lowered.hasPrefix("preset:"),
              !ProfileAvatarResolver.isImage(value) else { return nil }
        return value
    }

    var body: some View {
        let url = resolvedImageURL
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)
            if url == nil || shownURL != url {
                fallback
            }
            if let url {
                AsyncImageView(
                    url: url,
                    contentMode: .fill,
                    placeholderStyle: .clear,
                    onImageLoaded: { shownURL = url },
                    cacheScope: cacheScope
                )
                .frame(width: size, height: size)
                .clipShape(Circle())
                .id((cacheScope ?? VividCacheScope.artwork) + url)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var fallback: some View {
        if let textAvatar {
            Text(verbatim: textAvatar)
                .font(.system(size: size * 0.45))
        } else if let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
            Text(verbatim: String(initial).uppercased())
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(textColor)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.36))
                .foregroundStyle(Color.vividSecondaryText)
        }
    }
}

/// Turns a profile's avatar value into a loadable image URL.
enum ProfileAvatarResolver {
    private static let absolutePrefixes = ["http://", "https://", "data:image/", "file://"]
    private static let schemePrefixes = ["http://", "https://", "data:image/", "content://", "file://"]
    private static let imageMarkers = ["/", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".avif"]
    private static let slash = CharacterSet(charactersIn: "/")

    /// The server's own avatar URL, made absolute. SVG is left out because
    /// the image pipeline can't decode it.
    static func serverResolvedImageURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lowered = trimmed.lowercased()
        // Everything before the first question mark, which may be nothing.
        let path = lowered.firstIndex(of: "?").map { String(lowered[..<$0]) } ?? lowered
        if path.hasSuffix(".svg") || path.hasSuffix("/svg") { return nil }
        if absolutePrefixes.contains(where: { lowered.hasPrefix($0) }) { return trimmed }
        guard trimmed.hasPrefix("/"), let base = serverBase else { return nil }
        return base + trimmed
    }

    static func isImage(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.hasPrefix("preset:") { return false }
        if schemePrefixes.contains(where: { lowered.hasPrefix($0) }) || lowered.hasPrefix("/") { return true }
        return imageMarkers.contains { lowered.contains($0) }
    }

    static func imageURL(for value: String) -> String? {
        let lowered = value.lowercased()
        if lowered.hasPrefix("preset:") { return nil }
        if schemePrefixes.contains(where: { lowered.hasPrefix($0) }) { return value }
        guard value.contains("/") else { return value }
        guard let base = serverBase else { return nil }
        if value.hasPrefix("/") { return base + value }
        return base + "/" + value.trimmingCharacters(in: slash)
    }

    /// The active server URL without surrounding whitespace or slashes.
    private static var serverBase: String? {
        let base = ServerRegistry.shared.activeServerUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: slash)
        return base.isEmpty ? nil : base
    }
}

/// A gentle rocking while tiles are being arranged.
struct ProfileArrangeWobble: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(active: Bool) {
        self.active = active
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.phaseAnimator([-1.8, 1.8]) { view, angle in
                view.rotationEffect(.degrees(angle))
            } animation: { _ in
                .easeInOut(duration: 0.14)
            }
        } else {
            content
        }
    }
}
