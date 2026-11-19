#if os(tvOS)
import SwiftUI

// The Song pane of the Apple TV player HUD: "What's this song?" with Shazam.

extension TVPlayerInfoHUD {
    /// Identifies the song playing. The left column says what's happening
    /// (or the song found) and the right column holds the buttons.
    ///
    /// Focus (see docs/apple-tv-focus.md): every button is a native `Button`
    /// row and the focus engine owns movement. The first row keeps its place
    /// in every state and only its label and action change (Identify song,
    /// Stop, Save to Shazam, Try again), so a result arriving while it has
    /// focus doesn't drop focus. When a focused row does go (the item can't
    /// be identified any more), focus moves to the first row, or to the Song
    /// pill when there is none, so Menu always has a handler to bubble to.
    ///
    /// Listening carries on if the HUD closes; the result waits here.
    struct SongPane: View {
        let model: SongIdentificationModel
        /// Focuses the active pill.
        let onMoveToTabs: () -> Void

        @FocusState private var focusedRow: Row?

        enum Row: Hashable {
            /// Identify song, Stop, Save to Shazam or Try again.
            case primary
            /// Try again, beside a song found.
            case secondary
        }

        var body: some View {
            let phase = model.phase
            let blocked = blockedReason
            HStack(alignment: .top, spacing: 48) {
                PaneColumn(SongIdentificationText.title) {
                    details(phase: phase, blocked: blocked)
                }

                if blocked == nil {
                    PaneColumn("Shazam") {
                        VStack(spacing: 2) {
                            primaryRow(phase: phase)
                                .focused($focusedRow, equals: .primary)
                            if case let .found(match) = phase, match.shazamID != nil {
                                SongActionRow(title: SongIdentificationText.tryAgain) {
                                    model.identify()
                                }
                                .focused($focusedRow, equals: .secondary)
                            }
                        }
                    }
                    .focusSection()
                }
            }
            .defaultFocus($focusedRow, .primary, priority: .userInitiated)
            .onChange(of: rows) { _, rows in
                if let row = focusedRow, !rows.contains(row) { repairFocus(rows) }
            }
            .onChange(of: focusedRow) { old, new in
                // Focus leaving a row that's still here is the viewer moving
                // it (Up to the tabs). Leaving one that went needs a new home.
                guard new == nil, let old, !rows.contains(old) else { return }
                repairFocus(rows)
            }
        }

        // MARK: - Details

        @ViewBuilder
        private func details(
            phase: SongIdentificationModel.Phase,
            blocked: SongIdentificationModel.Unavailability?
        ) -> some View {
            if let blocked {
                bodyText(SongIdentificationText.unavailable(blocked))
            } else {
                switch phase {
                case .idle:
                    bodyText(SongIdentificationText.help)
                case .listening:
                    HStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text(SongIdentificationText.listening)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                case let .found(match):
                    foundDetails(match)
                case .notFound:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SongIdentificationText.notFoundTitle)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                        bodyText(SongIdentificationText.notFoundDetail)
                    }
                case let .failed(failure):
                    bodyText(SongIdentificationText.failure(failure))
                case let .refused(reason):
                    bodyText(SongIdentificationText.unavailable(reason))
                }
            }
        }

        private func foundDetails(_ match: SongMatch) -> some View {
            HStack(alignment: .top, spacing: 24) {
                SongArtwork(url: match.artworkURL, size: 160, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 6) {
                    // Shazam's text, shown as it is.
                    Text(match.title)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let artist = match.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func bodyText(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }

        // MARK: - Buttons

        /// One `SongActionRow` in every state, never a branch per state:
        /// a different branch would be a different view, and focus would
        /// drop when a result arrives.
        private func primaryRow(phase: SongIdentificationModel.Phase) -> some View {
            let title: String
            var trailingSymbol: String?
            let action: () -> Void
            switch phase {
            case .idle:
                title = SongIdentificationText.identify
                action = { model.identify() }
            case .listening:
                title = SongIdentificationText.stop
                action = { model.cancel() }
            case let .found(match) where match.shazamID == nil:
                // Shazam's library only takes songs with a Shazam ID, so
                // there's nothing to save and this row is Try again.
                title = SongIdentificationText.tryAgain
                action = { model.identify() }
            case .found:
                // Once saved the row does nothing but stays focusable, so
                // focus isn't pushed onto Try again, where a second Select
                // would throw the song away. Saving ignores repeat presses.
                title = SongIdentificationText.save(model.saveState)
                trailingSymbol = model.saveState == .saved ? "checkmark" : nil
                action = { model.saveToShazam() }
            case .notFound, .failed, .refused:
                title = SongIdentificationText.tryAgain
                action = { model.identify() }
            }
            return SongActionRow(title: title, trailingSymbol: trailingSymbol, action: action)
        }

        // MARK: - State

        /// Why the pane offers nothing to press: only reasons that last for
        /// the whole load, which read neither the playhead nor the buffer,
        /// so the buttons don't come and go while playback buffers. A
        /// passing reason shows once the viewer presses (`.refused`).
        private var blockedReason: SongIdentificationModel.Unavailability? {
            if model.isListening { return nil }
            return model.blockingReason
        }

        private var rows: [Row] {
            guard blockedReason == nil else { return [] }
            if case let .found(match) = model.phase, match.shazamID != nil { return [.primary, .secondary] }
            return [.primary]
        }

        /// The focused row went: the first row takes focus, or the Song
        /// pill when the pane has no buttons left.
        private func repairFocus(_ rows: [Row]) {
            if rows.contains(.primary) {
                focusedRow = .primary
            } else {
                onMoveToTabs()
            }
        }
    }

    /// A button row in the Song pane, in the HUD's row style.
    private struct SongActionRow: View {
        let title: String
        var trailingSymbol: String? = nil
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                SongActionRowLabel(title: title, trailingSymbol: trailingSymbol)
            }
            .buttonStyle(HUDRowButtonStyle())
            .accessibilityLabel(title)
        }
    }

    private struct SongActionRowLabel: View {
        let title: String
        let trailingSymbol: String?

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 22, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 20, weight: .semibold))
                }
            }
            .foregroundStyle(isFocused ? Color.black : Color.white)
        }
    }
}
#endif
