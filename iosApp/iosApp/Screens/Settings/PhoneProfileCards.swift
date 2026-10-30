#if os(iOS)
import SwiftUI

/// Who's watching: the saved profiles on this device, shown at launch when
/// the app is asked to choose one.
struct PhoneSavedProfilesScreen: View {
    @State private var store = TVSavedAccountStore.shared
    @State private var editor: EditorTarget?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if store.accounts.count > 4 {
                    ScrollView {
                        content.frame(minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(VividAppBackdrop())
            .navigationDestination(item: $editor) { target in
                AccountEditor(accountID: target.accountID)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            Spacer()
            VividLogoView(size: store.accounts.count > 4 ? 100 : 140)
            Text("Who’s watching?")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            AccountCards(layout: .whosWatching) { editor = EditorTarget(accountID: $0) }
            Spacer()
            VividCopyrightFooter()
                .padding(.bottom, 24)
        }
    }
}

extension PhoneSavedProfilesScreen {
    /// The account editor to push: an existing account, or a new one.
    struct EditorTarget: Hashable {
        let accountID: String?
    }

    /// The saved profiles as cards. Tapping one switches to it, or opens it
    /// for editing when it's signed out or (in Settings) already in use.
    /// Cards can be held and dragged into a new order.
    struct AccountCards: View {
        enum Layout {
            case whosWatching
            case settings
            case strip
        }

        let layout: Layout
        let openEditor: (String?) -> Void

        @State private var store = TVSavedAccountStore.shared
        @State private var drag: CardDrag?
        @State private var dragEndedAt: Date?
        @State private var frames: [String: CGRect] = [:]
        @State private var pinAccount: TVSavedAccount?
        @State private var pin = ""
        @State private var pinError: String?
        @GestureState private var isGesturing = false
        @Environment(AppRouter.self) private var router
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let space = "vivid.accountCards"

        private struct CardDrag {
            let id: String
            let startFrame: CGRect
            var translation: CGSize = .zero
            var order: [String]
            var lastTarget: String?
        }

        private struct SyncTrigger: Equatable {
            let isActive: Bool
            let isDragging: Bool
        }

        private var isSettings: Bool { layout != .whosWatching }
        private var avatarSize: CGFloat { isSettings ? 72 : 88 }
        private var tileSpacing: CGFloat { isSettings ? 8 : 12 }

        /// Accounts in the order being dragged, or as saved.
        private var accounts: [TVSavedAccount] {
            guard let drag else { return store.accounts }
            return drag.order.compactMap { id in store.accounts.first { $0.id == id } }
        }

        var body: some View {
            VStack(alignment: .trailing, spacing: 8) {
                arrangement
            }
            .disabled(store.busy)
            .coordinateSpace(.named(Self.space))
            .overlay(alignment: .topLeading) { draggedCopy }
            .task { await store.captureCurrent() }
            .task(id: SyncTrigger(isActive: scenePhase == .active, isDragging: drag != nil)) {
                guard scenePhase == .active, drag == nil else { return }
                while !Task.isCancelled {
                    await VividCloudAccountSync.shared.synchronize(router: router)
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { endDrag(saving: false) }
            }
            .onChange(of: isGesturing) { _, active in
                // A drag the system cancels never reports its end.
                guard !active else { return }
                Task { @MainActor in if drag != nil { endDrag(saving: false) } }
            }
            .onDisappear { endDrag(saving: false) }
            .alert("Profile", isPresented: errorShown) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
            .sheet(item: $pinAccount) { account in
                pinSheet(account)
            }
        }

        private var errorShown: Binding<Bool> {
            Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        }

        // MARK: Layouts

        @ViewBuilder
        private var arrangement: some View {
            switch layout {
            case .strip:
                strip
            case .settings:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 112), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(accounts) { card($0) }
                    if store.canAddAccount { addTile }
                }
            case .whosWatching where accounts.count < 3:
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 22) {
                            ForEach(accounts) { card($0) }
                            if store.canAddAccount { addTile }
                        }
                        .padding(.vertical, 12)
                        .frame(minWidth: proxy.size.width)
                    }
                }
                .frame(height: 170)
            case .whosWatching where accounts.count >= 5:
                VStack(spacing: 24) {
                    ForEach(Array(entries.profileRows(of: 3).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { entry in
                                Group {
                                    switch entry {
                                    case .account(let account): card(account)
                                    case .add: addTile
                                    }
                                }
                                .frame(width: 118)
                            }
                        }
                    }
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            case .whosWatching:
                VStack(spacing: 24) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                             count: accounts.count == 3 ? 3 : 2),
                              spacing: 24) {
                        ForEach(accounts) { card($0) }
                    }
                    if store.canAddAccount {
                        addTile.frame(width: 112)
                    }
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
        }

        private enum Entry: Identifiable {
            case account(TVSavedAccount)
            case add

            var id: String {
                switch self {
                case .account(let account): account.id
                case .add: "vivid.addProfile"
                }
            }
        }

        private var entries: [Entry] {
            accounts.map(Entry.account) + (store.canAddAccount ? [.add] : [])
        }

        private var strip: some View {
            VStack(spacing: 10) {
                ForEach(accounts) { account in
                    let current = isCurrent(account)
                    Button { tap(account) } label: {
                        avatar(account, size: 36)
                            .overlay {
                                if current { Circle().strokeBorder(.white, lineWidth: 2) }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(current ? Text("\(account.displayName), current account") : Text(account.displayName))
                }
                if store.canAddAccount {
                    Button { openEditor(nil) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Profile")
                }
            }
            .padding(.vertical, 7)
            .frame(width: 50)
            .vividGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
        }

        // MARK: Cards

        private func card(_ account: TVSavedAccount) -> some View {
            Button { tap(account) } label: {
                tile(account)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .opacity(drag?.id == account.id ? 0 : 1)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[account.id] = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Hold and drag onto another profile to reorder. Release to save.")
            .accessibilityAction(named: "Move earlier") { move(account.id, by: -1) }
            .accessibilityAction(named: "Move later") { move(account.id, by: 1) }
            .simultaneousGesture(reorderGesture(for: account))
        }

        private func tile(_ account: TVSavedAccount) -> some View {
            let current = isSettings && isCurrent(account)
            return VStack(spacing: tileSpacing) {
                avatar(account, size: avatarSize)
                    .overlay {
                        if current { Circle().strokeBorder(.white, lineWidth: 3) }
                    }
                    .accessibilityLabel(current ? Text("Current account") : Text(account.displayName))
                VStack(spacing: 4) {
                    Text(account.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(account.serverName ?? account.defaultServerLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if store.needsLogin(account) {
                        Text("Signed out")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: layout == .whosWatching && store.accounts.count < 3 ? 112 : nil)
            .frame(maxWidth: layout == .whosWatching && store.accounts.count < 3 ? nil : .infinity)
        }

        private var addTile: some View {
            Button { openEditor(nil) } label: {
                VStack(spacing: tileSpacing) {
                    Image(systemName: "plus")
                        .font(.system(size: 32))
                        .frame(width: avatarSize, height: avatarSize)
                        .background(.white.opacity(0.12), in: Circle())
                    Text("Add Profile")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: isSettings ? nil : 112)
                .frame(maxWidth: isSettings ? .infinity : nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }

        private func avatar(_ account: TVSavedAccount, size: CGFloat) -> some View {
            let profile = account.profile
            return ProfileAvatarView(avatar: profile?.avatarEmoji, imageUrl: imageURL(for: account),
                                     name: account.displayName, size: size,
                                     cacheScope: profile.map {
                                         VividCacheScope.key(serverID: account.serverID, accountID: account.userID, profileID: $0.id)
                                     })
        }

        /// A server-relative image path is joined to the account's server.
        private func imageURL(for account: TVSavedAccount) -> String? {
            guard let url = account.profile?.avatarImageUrl else { return nil }
            guard url.hasPrefix("/"), let server = ServerRegistry.shared.entry(with: account.serverID) else { return url }
            let base = server.url.hasSuffix("/") ? String(server.url.dropLast()) : server.url
            return base + url
        }

        private func isCurrent(_ account: TVSavedAccount) -> Bool {
            account.id == store.activeID
                && !account.requiresLogin
                && AuthService.shared.isLoggedIn
                && account.serverID == ServerRegistry.shared.activeServerId
        }

        // MARK: Selecting

        private func tap(_ account: TVSavedAccount) {
            guard drag == nil, !store.busy else { return }
            if let ended = dragEndedAt, Date().timeIntervalSince(ended) < 0.2 { return }
            if store.needsLogin(account) || (isSettings && account.id == store.activeID) {
                openEditor(account.id)
            } else if store.hasPIN(account.id) {
                pin = ""
                pinError = nil
                pinAccount = account
            } else {
                Task { await store.select(account, router: router) }
            }
        }

        private func pinSheet(_ account: TVSavedAccount) -> some View {
            NavigationStack {
                Form {
                    SecureField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                    if let pinError {
                        Text(pinError).foregroundStyle(.red)
                    }
                    Button("Unlock") { unlock(account) }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .navigationTitle(account.displayName)
                .toolbar {
                    VividSheetCloseItem {
                        pinAccount = nil
                        pin = ""
                    }
                }
            }
            .vividGlassSheet()
        }

        private func unlock(_ account: TVSavedAccount) {
            if store.unlock(account.id, pin: pin) {
                pinAccount = nil
                pin = ""
                Task { await store.select(account, router: router) }
            } else {
                pinError = store.error ?? String(localized: "Incorrect PIN")
                pin = ""
            }
        }

        // MARK: Reordering

        private func move(_ id: String, by offset: Int) {
            let ids = store.accounts.map(\.id)
            let moved = VividCloudPreferencePolicy.moving(ids, id: id, by: offset)
            if moved != ids { store.saveAccountOrder(moved) }
        }

        private func reorderGesture(for account: TVSavedAccount) -> some Gesture {
            LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(coordinateSpace: .named(Self.space)))
                .updating($isGesturing) { _, state, _ in state = true }
                .onChanged { value in
                    guard case .second(true, let moved?) = value else { return }
                    dragChanged(account, moved)
                }
                .onEnded { value in
                    guard case .second(true, let moved?) = value else { return }
                    endDrag(saving: frames.values.contains { $0.insetBy(dx: -6, dy: -6).contains(moved.location) })
                }
        }

        private var cardAnimation: Animation? {
            reduceMotion ? nil : .easeInOut(duration: 0.18)
        }

        private func dragChanged(_ account: TVSavedAccount, _ value: DragGesture.Value) {
            if drag == nil {
                guard !store.busy, store.accounts.count > 1, let frame = frames[account.id] else { return }
                drag = CardDrag(id: account.id, startFrame: frame, order: store.accounts.map(\.id))
            }
            guard var current = drag, current.id == account.id else { return }
            current.translation = value.translation
            if let last = current.lastTarget,
               frames[last]?.insetBy(dx: -6, dy: -6).contains(value.location) == true {
                drag = current
                return
            }
            let target = frames.first { id, frame in
                id != current.id && frame.insetBy(dx: -6, dy: -6).contains(value.location)
            }?.key
            guard let target, let to = current.order.firstIndex(of: target),
                  let from = current.order.firstIndex(of: current.id) else {
                drag = current
                return
            }
            current.order.remove(at: from)
            current.order.insert(current.id, at: to)
            current.lastTarget = target
            withAnimation(cardAnimation) { drag = current }
        }

        private func endDrag(saving: Bool) {
            guard let finished = drag else { return }
            if saving { store.saveAccountOrder(finished.order) }
            dragEndedAt = Date()
            withAnimation(cardAnimation) { drag = nil }
        }

        @ViewBuilder
        private var draggedCopy: some View {
            if let drag, let account = store.accounts.first(where: { $0.id == drag.id }) {
                tile(account)
                    .foregroundStyle(.white)
                    .frame(width: drag.startFrame.width, height: drag.startFrame.height)
                    .scaleEffect(reduceMotion ? 1 : 1.04)
                    .position(x: drag.startFrame.midX + drag.translation.width,
                              y: drag.startFrame.midY + drag.translation.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif
