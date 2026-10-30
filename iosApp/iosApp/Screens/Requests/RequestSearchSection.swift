import SwiftUI

/// Seerr titles matching the Search page's query that aren't in the library yet.
@MainActor
@Observable
final class RequestSearchSectionViewModel {
    private(set) var results: [RequestMediaResult] = []

    @ObservationIgnored private var search: Task<Void, Never>?

    private static let delay: Duration = .milliseconds(300)
    private static let minimumQueryLength = 2
    private static let maximumResults = 12

    init() {}

    /// Clears the shown results and, after a short pause, searches Seerr for
    /// the query. Only the latest call can change the results.
    func onQueryChanged(_ query: String, mediaType: RequestMediaType = .all) {
        search?.cancel()
        search = nil
        results = []

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard TVSeerrConnectionStore.shared.isConfigured, trimmed.count >= Self.minimumQueryLength else { return }

        search = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let page = try? await TVSeerrConnectionStore.shared.search(trimmed) else { return }
            guard !Task.isCancelled, let self else { return }
            self.results = Self.shown(page.results, mediaType: mediaType)
        }
    }

    func apply(_ record: MediaRequest) {
        results = RequestRecordPatch.apply(record, to: results)
    }

    private static func shown(_ results: [RequestMediaResult], mediaType: RequestMediaType) -> [RequestMediaResult] {
        let kept = results.filter { result in
            guard result.availability != .available, result.mediaType != .unknown else { return false }
            return mediaType == .all || result.mediaType == mediaType
        }
        return Array(kept.prefix(maximumResults))
    }
}

/// The "Available to request" section below the library results on Search.
struct RequestSearchSectionView: View {
    let viewModel: RequestSearchSectionViewModel

    var body: some View {
        if !viewModel.results.isEmpty {
            RequestSearchSectionContent(viewModel: viewModel)
                .onChange(of: RequestsEventBus.shared.latest) { _, record in
                    guard let record else { return }
                    viewModel.apply(record)
                }
        }
    }
}

private struct RequestSearchSectionContent: View {
    let viewModel: RequestSearchSectionViewModel

    #if os(tvOS)
    private let sectionSpacing: CGFloat = 20
    #else
    private let sectionSpacing: CGFloat = 10
    #endif

    var body: some View {
        #if os(tvOS)
        stack
            .focusSection()
        #else
        stack
        #endif
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            header
            #if os(tvOS)
            RequestResultGrid(results: viewModel.results)
            #else
            RequestResultRail(results: viewModel.results)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.vividCaption)
                Text("Available to request")
                    .font(.vividHeadline)
            }
            .foregroundStyle(Color.vividOnSurface)
            Text("Not in the library yet · tap to request")
                .font(.vividSmall)
                .foregroundStyle(Color.vividSecondaryText)
        }
    }
}

#if os(tvOS)
/// Seven columns of result cards that exactly fill the grid's width.
private struct RequestResultGrid: View {
    let results: [RequestMediaResult]

    @State private var gridWidth: CGFloat = 1600

    private let columnCount = 7
    private let columnSpacing: CGFloat = 40

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: columnCount)
    }

    private var cardWidth: CGFloat {
        let gaps = columnSpacing * CGFloat(columnCount - 1)
        return max(1, (gridWidth - gaps) / CGFloat(columnCount))
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
            ForEach(results) { result in
                RequestResultCard(result: result, width: cardWidth)
            }
        }
        .padding(.vertical, 24)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            gridWidth = width
        }
    }
}
#endif
