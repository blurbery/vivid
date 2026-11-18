#if os(tvOS)
import ImageIO
import SwiftUI

/// Who's watching's profiles, on a shallow arc that turns to bring the
/// chosen one into the centre. With three or more places the arc wraps
/// around, so there are profiles on both sides. The whole arc is one focus
/// target: Left and Right turn it, centre opens the profile in the middle
/// and holding picks that profile up to arrange it.
struct TVProfileOrbit: View {
    /// Opens a profile's settings, or Add Profile's.
    let onNavigate: (TVAccountRoute) -> Void
    /// The profile in the centre; nil on Add Profile.
    let onSelectionChange: (TVSavedAccount?) -> Void

    @State private var store = TVSavedAccountStore.shared
    @State private var profileStore = CurrentProfileStore.shared
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var hasRequestedInitialFocus = false
    /// How far the arc has turned, in places. It keeps counting past the
    /// ends when the arc wraps, so a turn always takes the short way.
    @State private var rotation: Double = 0
    @State private var selectedID: String?
    @State private var pinAccount: TVSavedAccount?
    @State private var movingID: String?
    @State private var draftOrder: [String] = []
    /// The main colour of each profile's picture, for the glow, by
    /// ``TVProfileOrbitPlace/glowKey``.
    @State private var glowColours: [String: Color] = [:]
    /// The glow's colour, kept while it fades out on Add Profile.
    @State private var glowColour: Color?

    var body: some View {
        VStack(spacing: 26) {
            Button(action: activate) {
                TVProfileOrbitRing(
                    places: places,
                    rotation: rotation,
                    centreID: movingID,
                    showsFocus: isFocused,
                    isArranging: movingID != nil
                )
                .background { glow }
            }
            .buttonStyle(.vividFlat)
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left: move(-1)
                case .right: move(1)
                default: break
                }
            }
            .onExitCommand(perform: movingID == nil ? nil : { cancelArrangement() })
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in beginArrangement() })
            .accessibilityLabel(spokenLabel)
            .accessibilityHint(movingID == nil
                ? Text("Move left or right to choose a profile.")
                : Text("Move left or right, then press centre to drop and save."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(1)
                case .decrement: move(-1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Arrange Profiles") { beginArrangement() }

            caption
        }
        .disabled(store.busy || pinAccount != nil)
        .task {
            await profileStore.refresh(force: true)
            await store.captureCurrent()
        }
        .task(id: canTakeInitialFocus) {
            guard canTakeInitialFocus, !hasRequestedInitialFocus else { return }
            // Enabling the arc and removing the splash must reach the native
            // view tree before it is given focus.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled, canTakeInitialFocus, !hasRequestedInitialFocus else { return }
            isFocused = true
        }
        .onChange(of: isFocused) { _, focused in
            if focused { hasRequestedInitialFocus = true }
        }
        .onChange(of: places.map(\.id)) { _, ids in
            guard movingID == nil else { return }
            // Profiles arriving or leaving through iCloud keep the chosen
            // one in the centre.
            let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? min(selectedIndex, max(ids.count - 1, 0))
            rotation = Double(index)
            reportSelection()
        }
        .onAppear { reportSelection() }
        // The centred profile's colour first. Turning the arc runs it again,
        // which retries a picture that couldn't be read before.
        .task(id: [selectedPlace?.glowKey ?? ""] + places.map(\.glowKey)) {
            let centre = selectedPlace.map { [$0] } ?? []
            for place in centre + places where glowColours[place.glowKey] == nil {
                if let colour = await TVProfileGlow.colour(for: place) { glowColours[place.glowKey] = colour }
                if Task.isCancelled { return }
            }
        }
        .task(id: scenePhase == .active && movingID == nil) {
            guard scenePhase == .active, movingID == nil else { return }
            while !Task.isCancelled {
                await VividCloudAccountSync.shared.synchronize(router: router)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelArrangement() }
        }
        .onDisappear { cancelArrangement() }
        .alert("Profile", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .fullScreenCover(item: $pinAccount) { account in
            TVSavedAccountPINPrompt(account: account) { pin in
                if store.unlock(account.id, pin: pin) {
                    pinAccount = nil
                    Task { await store.select(account, router: router) }
                }
            }
        }
    }

    // MARK: Places

    private var accounts: [TVSavedAccount] {
        guard movingID != nil else { return store.accounts }
        let ids = VividCloudPreferencePolicy.ordered(store.accounts.map(\.id), preferred: draftOrder)
        let byID = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private var places: [TVProfileOrbitPlace] {
        var places = accounts.map { account in
            TVProfileOrbitPlace(
                id: account.id, name: account.displayName, account: account,
                profile: displayedProfile(account), avatarURL: avatarURL(account)
            )
        }
        if store.canAddAccount {
            places.append(TVProfileOrbitPlace(
                id: TVProfileOrbitPlace.addID, name: String(localized: "Add Profile"),
                account: nil, profile: nil, avatarURL: nil
            ))
        }
        return places
    }

    private var selectedIndex: Int {
        let count = places.count
        guard count > 0 else { return 0 }
        if let movingID, let index = places.firstIndex(where: { $0.id == movingID }) { return index }
        return ((Int(rotation.rounded()) % count) + count) % count
    }

    private var selectedPlace: TVProfileOrbitPlace? {
        let places = places
        return places.indices.contains(selectedIndex) ? places[selectedIndex] : nil
    }

    /// The others moving past the profile being arranged.
    private var shuffle: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var turn: Animation? {
        reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.18)
    }

    private func reportSelection() {
        let place = selectedPlace
        selectedID = place?.id
        onSelectionChange(place?.account)
    }

    // MARK: Glow

    /// A soft light in the centred profile's colour, drawn on the avatar
    /// so it stays centred behind it, and adding light to the posters
    /// rather than tinting them. Add Profile has none; the glow fades out
    /// in the colour it had.
    private var glow: some View {
        let place = selectedPlace
        let colour = place.flatMap { place in
            place.account.map { glowColours[place.glowKey] ?? TVProfileGlow.fallback(for: $0) }
        }
        let shown = colour ?? glowColour ?? .clear
        let size = TVProfileOrbitRing.avatarSize
        return RadialGradient(
            stops: [
                .init(color: shown.opacity(0.6), location: 0),
                .init(color: shown.opacity(0.22), location: 0.45),
                .init(color: .clear, location: 1)
            ],
            center: .center, startRadius: size * 0.3, endRadius: size * 2
        )
        .frame(width: size * 4, height: size * 4)
        .opacity(colour == nil ? 0 : 1)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.6), value: colour)
        .onChange(of: colour, initial: true) { _, colour in
            if let colour { glowColour = colour }
        }
    }

    // MARK: Caption

    /// The chosen profile's name and server, large under the arc.
    private var caption: some View {
        let place = selectedPlace
        return VStack(spacing: 8) {
            Text(verbatim: place?.name ?? " ")
                .font(.system(size: 54, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(verbatim: captionDetail(place))
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 1200)
        // The wall is brightest behind the arc, so the text carries its
        // own shade.
        .shadow(color: .black.opacity(0.7), radius: 14)
        .id(place?.id)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: place?.id)
        .accessibilityHidden(true)
    }

    private func captionDetail(_ place: TVProfileOrbitPlace?) -> String {
        guard let account = place?.account else { return " " }
        let server = account.serverName ?? account.defaultServerLabel
        if movingID != nil { return String(localized: "Move left or right, then press centre to drop and save.") }
        if account.requiresLogin { return "\(server) · \(String(localized: "Signed out"))" }
        return server
    }

    private var spokenLabel: Text {
        guard let place = selectedPlace else { return Text("Who’s watching?") }
        guard let account = place.account else { return Text(verbatim: place.name) }
        let name = account.displayName
        let server = account.serverName ?? account.defaultServerLabel
        if movingID != nil { return Text("Move \(name). Move left or right, then press centre to drop and save.") }
        if account.requiresLogin { return Text("\(name), signed out, \(server)") }
        return Text("\(name), \(server)")
    }

    // MARK: Actions

    private var canTakeInitialFocus: Bool {
        isEnabled && scenePhase == .active && !store.busy && !store.showsAnimation
            && store.error == nil && pinAccount == nil && movingID == nil && !places.isEmpty
    }

    private func move(_ step: Int) {
        if let movingID {
            withAnimation(shuffle) {
                draftOrder = VividCloudPreferencePolicy.moving(draftOrder, id: movingID, by: step)
            }
            return
        }
        let count = places.count
        guard count > 1 else { return }
        let target: Double
        if count >= TVProfileOrbitRing.wrapCount {
            target = rotation.rounded() + Double(step)
        } else {
            target = Double(min(max(selectedIndex + step, 0), count - 1))
        }
        guard target != rotation else { return }
        withAnimation(turn) { rotation = target }
        reportSelection()
    }

    private func activate() {
        if movingID != nil {
            _ = store.saveAccountOrder(draftOrder)
            endArrangement()
            return
        }
        guard let place = selectedPlace else { return }
        guard let account = place.account else {
            onNavigate(.editor(nil))
            return
        }
        if store.needsLogin(account) {
            onNavigate(.editor(account.id))
        } else if store.hasPIN(account.id) {
            pinAccount = account
        } else {
            Task { await store.select(account, router: router) }
        }
    }

    private func beginArrangement() {
        guard movingID == nil, !store.busy, store.accounts.count > 1,
              let account = selectedPlace?.account else { return }
        draftOrder = store.accounts.map(\.id)
        movingID = account.id
    }

    private func cancelArrangement() {
        guard movingID != nil else { return }
        withAnimation(shuffle) { draftOrder = store.accounts.map(\.id) }
        endArrangement()
    }

    /// Leaves arranging with the moved profile still in the centre.
    private func endArrangement() {
        guard let id = movingID else { return }
        let order = store.accounts.map(\.id)
        movingID = nil
        draftOrder = []
        rotation = Double(order.firstIndex(of: id) ?? 0)
        reportSelection()
    }

    // MARK: Avatars

    private func displayedProfile(_ account: TVSavedAccount) -> UserProfile? {
        if store.isCurrent(account), let profile = profileStore.profile,
           profile.id == AuthService.shared.profileId { return profile }
        return account.profile
    }

    private func avatarURL(_ account: TVSavedAccount) -> String? {
        guard let raw = displayedProfile(account)?.avatarImageUrl else { return nil }
        if raw.hasPrefix("/"), let server = ServerRegistry.shared.entry(with: account.serverID) {
            return server.url + raw
        }
        return raw
    }
}

/// One place on the arc: a saved profile, or Add Profile.
struct TVProfileOrbitPlace: Identifiable, Equatable {
    static let addID = "vivid.add-profile"

    let id: String
    let name: String
    let account: TVSavedAccount?
    let profile: UserProfile?
    let avatarURL: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.account == rhs.account && lhs.avatarURL == rhs.avatarURL
    }

    /// Tells the glow's colours apart: a new picture, from its image URL or
    /// an image stored as the avatar, takes a new colour.
    var glowKey: String { [id, avatarURL ?? "", profile?.avatarEmoji ?? ""].joined(separator: "|") }

    /// A steady colour of the profile's own, for the glow of a profile
    /// whose picture gives none, from 0 to 1.
    static func hue(for account: TVSavedAccount) -> Double {
        let total = account.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return Double(total) / 360
    }
}

/// Draws the arc for a given turn. The turn is animatable, so every place
/// follows the curve on its way round rather than cutting straight across.
struct TVProfileOrbitRing: View, Animatable {
    /// From this many places the arc wraps around.
    static let wrapCount = 3
    static let avatarSize: CGFloat = 210

    let places: [TVProfileOrbitPlace]
    var rotation: Double
    /// While arranging, the profile held in the centre whatever the turn.
    let centreID: String?
    let showsFocus: Bool
    let isArranging: Bool

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    var body: some View {
        let centre = centreID.flatMap { id in places.firstIndex { $0.id == id } }.map(Double.init) ?? rotation
        ZStack {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                let offset = offset(of: index, from: centre)
                let distance = abs(offset)
                TVProfileOrbitAvatar(
                    place: place,
                    isCentre: distance < 0.5,
                    showsFocus: showsFocus && distance < 0.5,
                    isArranging: isArranging,
                    labelOpacity: min(1, distance)
                )
                .scaleEffect(max(0.4, 1 - 0.45 * min(distance, 1) - 0.07 * max(0, distance - 1)))
                .offset(
                    x: (offset < 0 ? -1 : 1) * (365 * distance - 35 * distance * distance),
                    y: 22 * offset * offset
                )
                .opacity(opacity(at: distance))
                .zIndex(10 - distance)
            }
        }
        .frame(maxWidth: .infinity)
        // The centre avatar and its focus ring; the names hang below.
        .frame(height: Self.avatarSize + 24)
    }

    private var wraps: Bool { places.count >= Self.wrapCount }

    /// How many places a profile sits from the centre, negative to the left.
    private func offset(of index: Int, from centre: Double) -> Double {
        let raw = Double(index) - centre
        guard wraps else { return raw }
        let count = Double(places.count)
        return raw - count * (raw / count).rounded()
    }

    /// Fades with distance, and to nothing at the far side of a wrapping
    /// arc, where a place crosses from one end to the other.
    private func opacity(at distance: Double) -> Double {
        var value = max(0.3, 1 - 0.22 * distance) * min(1, max(0, (3.5 - distance) / 0.5))
        if wraps {
            value *= min(1, max(0, (Double(places.count) / 2 - distance) / 0.5))
        }
        return value
    }
}

/// A profile's avatar on the arc with its name underneath. The one in the
/// centre floats, wears the focus ring and leaves its name to the caption.
private struct TVProfileOrbitAvatar: View {
    let place: TVProfileOrbitPlace
    let isCentre: Bool
    let showsFocus: Bool
    let isArranging: Bool
    let labelOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRising = false

    private var size: CGFloat { TVProfileOrbitRing.avatarSize }
    private var floats: Bool { isCentre && !isArranging && !reduceMotion }

    var body: some View {
        avatar
            .overlay {
                Circle().strokeBorder(.white, lineWidth: 5)
                    .padding(-12)
                    .opacity(showsFocus ? 1 : 0)
            }
            .offset(y: floats ? (isRising ? -7 : 7) : 0)
            .animation(
                floats ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true) : .easeOut(duration: 0.3),
                value: isRising
            )
            .modifier(ProfileArrangeWobble(active: isArranging && !isCentre))
            // The name hangs under the avatar without taking room, so the
            // centre avatar's caption can sit right beneath it.
            .overlay(alignment: .top) {
                Text(verbatim: place.name)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: size * 1.5)
                    .shadow(color: .black.opacity(0.7), radius: 14)
                    .opacity(labelOpacity)
                    .offset(y: size + 18)
            }
        .onChange(of: floats, initial: true) { _, floats in isRising = floats }
    }

    @ViewBuilder
    private var avatar: some View {
        if let account = place.account {
            ProfileAvatarView(
                avatar: place.profile?.avatarEmoji,
                imageUrl: place.avatarURL, name: account.displayName, size: size,
                cacheScope: place.profile.map {
                    VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: String($0.id))
                }
            )
        } else {
            Image(systemName: "plus")
                .font(.system(size: 84, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.white.opacity(0.14), in: Circle())
        }
    }
}

/// The glow's colour for a profile: the main colour of its picture, lifted
/// to a bright light, or a steady colour of its own when it has an emoji or
/// initial instead.
enum TVProfileGlow {
    static func fallback(for account: TVSavedAccount) -> Color {
        Color(hue: TVProfileOrbitPlace.hue(for: account), saturation: 0.6, brightness: 0.9)
    }

    /// Reads the picture the avatar already loaded; nil without one.
    static func colour(for place: TVProfileOrbitPlace) async -> Color? {
        guard let account = place.account else { return nil }
        let avatar = place.profile?.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = ProfileAvatarResolver.serverResolvedImageURL(place.avatarURL)
            ?? (ProfileAvatarResolver.isImage(avatar) ? ProfileAvatarResolver.imageURL(for: avatar) : nil)
        guard let raw, let url = URL(string: raw) else { return nil }
        let scope = place.profile.map {
            VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: String($0.id))
        } ?? VividCacheScope.artwork
        guard let data = try? await VividImagePipeline.shared.data(for: VividImageRequest(url: url, cacheScope: scope))
        else { return nil }
        return await Task.detached(priority: .utility) { () -> Color? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 48
                  ] as CFDictionary),
                  let tint = HeroBackdropPalette.dominantTint(of: thumbnail) else { return nil }
            return bright(tint)
        }.value
    }

    /// The sampled colour is dimmed for gradients, so this keeps its hue
    /// and raises it to a light. A picture with little colour glows white.
    private static func bright(_ tint: Color) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(tint).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.15 else { return Color(white: 0.85) }
        return Color(hue: hue, saturation: min(max(saturation, 0.45), 0.8), brightness: 0.95)
    }
}
#endif
