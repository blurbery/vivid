import SwiftUI

/// Warm palette for profile tiles. The tint is the primary identity signal
/// — users recognize their profile by color before they recognize the
/// emoji. Saturation is kept under ~70% so the tiles read as "paper" in
/// front of pure-black, not as neon chips.
enum ProfileTilePalette {
    static let colors: [Color] = [
        Color(red: 0.850, green: 0.460, blue: 0.380),  // coral
        Color(red: 0.400, green: 0.560, blue: 0.720),  // slate blue
        Color(red: 0.690, green: 0.540, blue: 0.400),  // warm tan
        Color(red: 0.460, green: 0.620, blue: 0.520),  // sage
        Color(red: 0.780, green: 0.480, blue: 0.520),  // dusty rose
        Color(red: 0.560, green: 0.480, blue: 0.720),  // lavender
        Color(red: 0.360, green: 0.580, blue: 0.620),  // teal
        Color(red: 0.780, green: 0.640, blue: 0.380),  // amber
    ]

    /// Stable derivation from profile id. `hashValue` varies per-launch under
    /// some Swift versions but within a single launch it's consistent, which
    /// is enough — the screen regenerates each session.
    static func tint(for profileId: String) -> Color {
        var h: UInt64 = 5381
        for byte in profileId.utf8 {
            h = ((h << 5) &+ h) &+ UInt64(byte)
        }
        return colors[Int(h % UInt64(colors.count))]
    }
}

#if os(tvOS)
private let tileSize: CGFloat = 280
private let tileCornerRadius: CGFloat = 28
private let emojiSize: CGFloat = 140
private let initialSize: CGFloat = 120
private let nameSize: CGFloat = 28
private let focusScale: CGFloat = 1.10
#else
private let tileSize: CGFloat = 140
private let tileCornerRadius: CGFloat = 18
private let emojiSize: CGFloat = 72
private let initialSize: CGFloat = 56
private let nameSize: CGFloat = 17
private let focusScale: CGFloat = 1.05
#endif

/// A profile tile — square, tinted, with the avatar centered inside.
/// The tint is the identity; the avatar rides on top. On focus the whole
/// tile lifts with a white ring and a colored halo matching its tint.
struct ProfileTile: View {
    let profile: UserProfile
    var isRemembered: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var tint: Color {
        ProfileTilePalette.tint(for: profile.id)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 20) {
                tileBody
                    .frame(width: tileSize, height: tileSize)
                    // Focus ring sits *outside* the tile so it never crops
                    // content. Inset by a negative amount so the stroke
                    // extends past the tile bounds.
                    .overlay {
                        RoundedRectangle(cornerRadius: tileCornerRadius + 4)
                            .inset(by: -4)
                            .stroke(isFocused ? Color.white : Color.clear, lineWidth: 4)
                    }
                    .scaleEffect(isFocused ? focusScale : 1.0)
                    // Stacked shadows: a colored halo from the tint + a
                    // neutral drop shadow for lift. The halo is what sells
                    // the "this profile is alive" feel when focused.
                    .shadow(color: tint.opacity(isFocused ? 0.55 : 0),
                            radius: isFocused ? 44 : 0, y: 0)
                    .shadow(color: .black.opacity(isFocused ? 0.5 : 0),
                            radius: isFocused ? 22 : 0, y: isFocused ? 14 : 0)

                Text(profile.name)
                    .font(.system(size: nameSize, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.72))
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
        .focused($isFocused)
        .accessibilityLabel(profile.name)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var tileBody: some View {
        ZStack {
            // Primary tile fill: the tint. A thin inner highlight at the
            // top helps the tile read as a physical surface rather than a
            // flat swatch.
            RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                .fill(tint)
                .overlay(
                    RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )

            // Avatar content. Emoji and letter fallbacks render directly
            // on the tint; image avatars clip to the tile shape.
            avatarContent

            // Child / lock badges ride in the top-right corner.
            if profile.hasPin || profile.isChild {
                VStack {
                    HStack(spacing: 6) {
                        Spacer()
                        if profile.isChild {
                            badgeChip(systemImage: "leaf.fill")
                        }
                        if profile.hasPin {
                            badgeChip(systemImage: "lock.fill")
                        }
                    }
                    Spacer()
                }
                .padding(12)
            }

            if isRemembered {
                VStack {
                    Spacer()
                    HStack {
                        Text(rememberedBadgeLabel)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.48), in: .capsule)
                        Spacer()
                    }
                }
                .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var avatarContent: some View {
        let avatar = profile.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let serverURL = ProfileAvatarResolver.serverResolvedImageURL(profile.avatarImageUrl) {
            AsyncImageView(url: serverURL, contentMode: .fill)
                .frame(width: tileSize, height: tileSize)
        } else if ProfileAvatarResolver.isImage(avatar) {
            // Server image avatars clip to the full tile
            // bounds for a cinematic poster effect.
            if let url = ProfileAvatarResolver.imageURL(for: avatar) {
                AsyncImageView(url: url, contentMode: .fill)
                    .frame(width: tileSize, height: tileSize)
            } else {
                initialFallback
            }
        } else if !avatar.isEmpty, !avatar.lowercased().hasPrefix("preset:") {
            Text(avatar)
                .font(.system(size: emojiSize))
        } else {
            initialFallback
        }
    }

    private var initialFallback: some View {
        Text(initial)
            .font(.system(size: initialSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        return String(trimmed.prefix(1)).uppercased()
    }

    private func badgeChip(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(Circle().fill(Color.black.opacity(0.35)))
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isRemembered { values.append(rememberedAccessibilityValue) }
        if profile.hasPin { values.append("PIN protected") }
        if profile.isChild { values.append("Child profile") }
        return values.joined(separator: ", ")
    }

    private var rememberedBadgeLabel: String {
        #if os(tvOS)
        "APPLE TV USER"
        #else
        "LAST USED"
        #endif
    }

    private var rememberedAccessibilityValue: String {
        #if os(tvOS)
        "Paired with this Apple TV user"
        #else
        "Last used"
        #endif
    }
}

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
