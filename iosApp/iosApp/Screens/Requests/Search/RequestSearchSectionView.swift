import SwiftUI

/// The "Available to request" section embedded in the library `SearchView`
/// below local results: TMDB matches the library can't answer, one tap from
/// the query the user already typed. Renders nothing when the feature is
/// disabled or there's nothing requestable to show, so the search screen is
/// untouched on servers without requests.
struct RequestSearchSectionView: View {
    #if os(tvOS)
    @State private var availableWidth: CGFloat = 1600
    #endif
    let viewModel: RequestSearchSectionViewModel
    @Environment(AppRouter.self) private var router

    var body: some View {
        if !viewModel.results.isEmpty {
            VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.vividCaption)
                        Text("Available to request")
                            .font(.vividHeadline)
                    }
                    .foregroundColor(.vividOnSurface)

                    Text("Not in the library yet · tap to request")
                        .font(.vividSmall)
                        .foregroundColor(.vividSecondaryText)
                }

                #if os(tvOS)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 7), alignment: .leading, spacing: 60) {
                    ForEach(viewModel.results) { result in
                        RequestMediaCard(result: result, cardWidth: max(1, (availableWidth - 240) / 7), onTap: { router.openRequestResult(result) })
                    }
                }
                .padding(.vertical, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
                #else
                RequestCardRail(items: viewModel.results) { result in
                    RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusSection()
            #endif
            .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
                if let update {
                    viewModel.applyRequestUpdate(update)
                }
            }
        }
    }

}
