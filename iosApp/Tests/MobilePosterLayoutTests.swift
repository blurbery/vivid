import SwiftUI
import XCTest
@testable import Vivid

@MainActor
final class MobilePosterLayoutTests: XCTestCase {
    private let windowWidths: [CGFloat] = [320, 375, 507, 744, 768, 820, 834, 1024, 1194, 1366]

    func testPosterCardsFitCompactAndRegularGridCells() {
        for windowWidth in windowWidths {
            let availableWidth = windowWidth - 32
            for size in CardPosterSize.allCases {
                for columnCount in [3, 4, 5, 6] {
                    for spacing in [CGFloat(8), CGFloat(12)] {
                        let cellWidth = (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
                        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
                            containerWidth: availableWidth,
                            columnCount: columnCount,
                            spacing: spacing
                        )
                        let host = UIHostingController(rootView:
                            MediaCard(
                                title: "A movie or series with a long title",
                                posterUrl: "",
                                year: 2026,
                                action: {},
                                cardWidthOverride: fittedWidth / size.scale
                            )
                            .environment(AppRouter())
                            .environmentObject(OverlayPrefsStore.shared)
                            .environment(\.homeCardPresentation, .init(posterSize: size, caption: .titleMetadata))
                        )
                        let rendered = host.sizeThatFits(in: CGSize(width: cellWidth, height: 1000))
                        XCTAssertLessThanOrEqual(rendered.width, cellWidth + 0.5,
                            "Poster exceeds its cell at window width \(windowWidth), \(columnCount) columns, \(size)")
                        XCTAssertGreaterThan(rendered.width, 0)
                        XCTAssertGreaterThan(rendered.height, rendered.width)
                    }
                }
            }
        }
    }

    func testUnconstrainedPosterReproducesNarrowWindowOverflow() {
        let cellWidth: CGFloat = (320 - 32 - 16) / 3
        let host = UIHostingController(rootView:
            MediaCard(title: "Series", posterUrl: "", action: {})
                .environment(AppRouter())
                .environmentObject(OverlayPrefsStore.shared)
                .environment(\.homeCardPresentation, .init(posterSize: .large, caption: .title))
        )
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: cellWidth, height: 1000)).width, cellWidth)
    }

    func testFittedPostersRespondToWindowResizing() {
        let widths: [CGFloat] = [1024, 507, 320, 1366]
        for width in widths {
            let columns = width < 600 ? 3 : 5
            let fitted = AdaptiveColumns.fittedPosterWidth(
                containerWidth: width - 32, columnCount: columns, spacing: 12
            )
            XCTAssertLessThanOrEqual(fitted * CGFloat(columns) + CGFloat(columns - 1) * 12, width - 32 + 0.5)
            XCTAssertLessThanOrEqual(fitted, VividTheme.posterCardWidth)
        }
    }

    func testNavigationBarStaysCompactAndFitsNarrowWindows() {
        for windowWidth in windowWidths {
            for itemCount in [3, 4, 5, 6] {
                let host = UIHostingController(rootView: MobileGlassNavigationBar(
                    items: (0..<itemCount).map { .init(id: "\($0)", title: "Tab \($0)") },
                    selectedID: "0",
                    onSelect: { _ in }
                ))
                let available = windowWidth - 32
                let rendered = host.sizeThatFits(in: CGSize(width: available, height: 100))
                XCTAssertEqual(rendered.width, min(420, available), accuracy: 0.5)
                XCTAssertEqual(rendered.height, 50, accuracy: 0.5)
            }
        }
    }
}
