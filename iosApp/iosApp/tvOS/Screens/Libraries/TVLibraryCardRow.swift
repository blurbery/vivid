#if os(tvOS)
import SwiftUI

extension TVMainTabView {
    /// The Library tab's row of libraries: landscape cards the size of
    /// Home's Continue Watching cards, each with its library's name below.
    struct LibraryCardRow: View {
        let libraries: [Library]
        let focusedLibraryId: FocusState<Int?>.Binding
        /// The card focus lands on when it enters the row from elsewhere.
        let defaultLibraryId: Int?
        let onOpen: (Library) -> Void
        let onMoveUp: () -> Void

        @State private var homeCards = TVHomeCardPreferences.shared

        private var cardSize: CGSize {
            let width = VividTheme.thumbnailCardWidth * homeCards.presentation.posterSize.scale
            return CGSize(width: width, height: width * VividTheme.thumbnailCardHeight / VividTheme.thumbnailCardWidth)
        }

        var body: some View {
            let size = cardSize
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(libraries) { library in
                        card(library, size: size)
                    }
                }
                .padding(.horizontal, VividTheme.safePadding)
                .padding(.vertical, TVHomeRowGeometry.cardPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
            .defaultFocus(focusedLibraryId, defaultLibraryId, priority: .userInitiated)
            .onMoveCommand { direction in
                if direction == .up { onMoveUp() }
            }
        }

        private func card(_ library: Library, size: CGSize) -> some View {
            let isFocused = focusedLibraryId.wrappedValue == library.id
            return VStack(alignment: .leading, spacing: 14) {
                Button { onOpen(library) } label: {
                    artwork(library, size: size)
                }
                .buttonStyle(.card)
                .focused(focusedLibraryId, equals: library.id)
                .accessibilityLabel(Text(verbatim: library.name))
                .accessibilityHint(Text("Open library"))
                Text(verbatim: LibraryNames.cardLabel(for: library, among: libraries))
                    .font(.vividPosterTitle)
                    .foregroundStyle(isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: size.width, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .frame(width: size.width)
        }

        /// The library's own image, or its symbol on a plain tile when the
        /// server has none.
        @ViewBuilder
        private func artwork(_ library: Library, size: CGSize) -> some View {
            let url = library.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: Self.symbol(for: library))
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                if !url.isEmpty {
                    AsyncImageView(url: url, thumbhash: nil, targetSize: size, contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        private static func symbol(for library: Library) -> String {
            if library.isMixedLibrary { return library.navigationIcon }
            return library.isSeriesLibrary ? PrimaryMenuBuiltin.series.navigationIcon
                : PrimaryMenuBuiltin.movies.navigationIcon
        }
    }

    /// Library names as cards and pages show them.
    enum LibraryNames {
        /// The shortened name, unless another library in the row shortens to
        /// the same text; then the full name.
        static func cardLabel(for library: Library, among libraries: [Library]) -> String {
            let short = shortLabel(for: library)
            let collides = libraries.contains { other in
                other.id != library.id
                    && shortLabel(for: other).localizedCaseInsensitiveCompare(short) == .orderedSame
            }
            return collides ? library.name : short
        }

        /// A series library drops a leading "TV Shows" and the like, a movie
        /// library a leading "Movies"; a mixed library keeps its name.
        static func shortLabel(for library: Library) -> String {
            if library.isMixedLibrary {
                return library.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return shortLabel(library.name, isSeriesPage: library.isSeriesLibrary)
        }

        /// Drops a leading "Movies", "TV Shows" and the like when a separator
        /// follows it.
        static func shortLabel(_ name: String, isSeriesPage: Bool) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = isSeriesPage ? #"series|tv\s+shows?|shows?"# : #"movies?"#
            let separators = "[\\s:\u{2013}\u{2014}_\\-]+"
            guard let match = trimmed.range(
                of: "^(?:\(words))\(separators)",
                options: [.regularExpression, .caseInsensitive]
            ) else { return trimmed }
            let rest = trimmed[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? trimmed : rest
        }
    }
}
#endif
