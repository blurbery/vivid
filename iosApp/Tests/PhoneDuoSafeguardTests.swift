import SwiftUI
import XCTest
@testable import Vivid

/// Every iPhone Duo layout keys off `PhoneDuo.isDuo` or `onDuo`. CI runs
/// these on an iPhone that isn't a Duo, so a Duo change that reaches the
/// layouts other iPhones and iPads use fails here. They skip on a Duo.
@MainActor
final class PhoneDuoSafeguardTests: XCTestCase {
    private func skipOnDuo() throws {
        try XCTSkipIf(PhoneDuo.isDuo, "Checks devices other than the iPhone Duo")
    }

    func testDuoGateIsOff() throws {
        try skipOnDuo()
        XCTAssertFalse(PhoneDuo.isInnerScreen(CGSize(width: 669, height: 951)))
        XCTAssertFalse(PhoneDuo.isInnerScreen(CGSize(width: 1024, height: 1366)))
        for sizeClass in [UserInterfaceSizeClass.compact, .regular, nil] {
            XCTAssertFalse(PhoneDuo.usesWideLayout(sizeClass))
            XCTAssertEqual(PhoneDuo.pageTabsMaxWidth(sizeClass), .infinity)
            XCTAssertEqual(PhoneDuo.usesPhoneDetailLayout(sizeClass), sizeClass != .regular)
        }
    }

    func testDuoEnvironmentDefaultsChangeNothing() throws {
        try skipOnDuo()
        let environment = EnvironmentValues()
        XCTAssertFalse(environment.usesDuoSideTabBar)
        XCTAssertNil(environment.duoSideStrip)
        XCTAssertNil(environment.duoControlCorner)
        XCTAssertFalse(environment.duoStripBackHidden)
        XCTAssertFalse(environment.phoneDetailActionsShareRow)
    }

    func testOnDuoLeavesTheViewAsItWas() throws {
        try skipOnDuo()
        let host = UIHostingController(rootView:
            Color.clear.frame(width: 10, height: 10).onDuo { $0.padding(100) }
        )
        let size = host.sizeThatFits(in: CGSize(width: 500, height: 500))
        XCTAssertEqual(size.width, 10, accuracy: 0.5)
        XCTAssertEqual(size.height, 10, accuracy: 0.5)
    }

    /// Status bar widgets only move controls on the Duo.
    func testStatusAreaNeverMovesControls() throws {
        try skipOnDuo()
        DuoStatusArea.shared.update(bandBottom: 400, screen: CGSize(width: 466, height: 678))
        DuoStatusArea.shared.update(bandBottom: 400, screen: CGSize(width: 951, height: 669))
        XCTAssertEqual(DuoStatusArea.shared.growth, 0)
    }

    func testOrientationKeepsTheUsualPolicy() throws {
        try skipOnDuo()
        let coordinator = PlayerOrientationCoordinator.shared
        XCTAssertEqual(coordinator.rotatesBrowsing, UIDevice.current.userInterfaceIdiom == .pad)
        coordinator.setDuoTabletop(true)
        XCTAssertFalse(coordinator.isDuoTabletop)
    }

    /// The row under Play uses the Duo's larger circles (blurbery's change,
    /// 10 November 2026). Its slots grow for a long caption; Play's shared
    /// row keeps fixed slots.
    func testActionMetricsUseTheLargerCircles() throws {
        try skipOnDuo()
        let stacked = PhoneLabeledActionMetrics(sharesRow: false)
        XCTAssertEqual(stacked.circle, 52)
        XCTAssertEqual(stacked.iconSize, 21)
        XCTAssertNil(stacked.slotWidth)
        XCTAssertEqual(PhoneLabeledActionMetrics(sharesRow: true).slotWidth, 52)
    }

    /// Five actions keep 14-point gaps where they fit, close the gaps first
    /// in a narrow window, and only then shrink the slots, always centred.
    func testActionRowClosesItsGapsBeforeShrinkingSlots() {
        let five = Array(repeating: CGFloat(52), count: 5)
        let roomy = MobileActionRowLayout.placement(widths: five, available: 370, spacing: 14, minSpacing: 4)
        XCTAssertEqual(roomy.gap, 14)
        XCTAssertEqual(roomy.widths, five)
        XCTAssertEqual(roomy.leading, (370 - 316) / 2, accuracy: 0.01)

        let narrow = MobileActionRowLayout.placement(widths: five, available: 288, spacing: 14, minSpacing: 4)
        XCTAssertEqual(narrow.gap, 7, accuracy: 0.01)
        XCTAssertEqual(narrow.widths, five)

        // Long captions shrink back towards the circle, never below it.
        let long: [CGFloat] = [52, 80, 52, 90, 52]
        let shared = MobileActionRowLayout.placement(widths: long, available: 300, spacing: 14, minSpacing: 4)
        XCTAssertEqual(shared.gap, 4)
        XCTAssertLessThanOrEqual(shared.widths.reduce(0, +) + 16, 300)
        XCTAssertTrue(shared.widths.allSatisfy { $0 >= 52 })

        let tight = MobileActionRowLayout.placement(widths: five, available: 250, spacing: 14, minSpacing: 4)
        XCTAssertEqual(tight.widths, five, "Never narrower than the circle")
        XCTAssertEqual(tight.leading, 0, accuracy: 0.01)
    }

    /// Play stays above the actions with each detail page's own gap (14
    /// points, 12 on season pages), even at a regular width, where the Duo's
    /// inner screen puts them in one row.
    func testPrimaryActionsStayStackedWithEachPagesGap() throws {
        try skipOnDuo()
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let movie = UIHostingController(rootView:
                PhoneDetailPrimaryActions {
                    Color.clear.frame(width: 100, height: 50)
                } actions: {
                    Color.clear.frame(width: 100, height: 58)
                }
                .environment(\.horizontalSizeClass, sizeClass)
            )
            let season = UIHostingController(rootView:
                PhoneDetailPrimaryActions(stackedSpacing: 12) {
                    Color.clear.frame(width: 100, height: 50)
                } actions: {
                    Color.clear.frame(width: 100, height: 58)
                }
                .environment(\.horizontalSizeClass, sizeClass)
            )
            let proposal = CGSize(width: 400, height: 1000)
            XCTAssertEqual(movie.sizeThatFits(in: proposal).height, 50 + 14 + 58, accuracy: 0.5)
            XCTAssertEqual(season.sizeThatFits(in: proposal).height, 50 + 12 + 58, accuracy: 0.5)
        }
    }

    /// The row keeps the full width, with its actions centred in it and the
    /// rule under them.
    func testActionRowKeepsItsFullWidthAndRule() throws {
        try skipOnDuo()
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let host = UIHostingController(rootView:
                PhoneLabeledActionRow {
                    Color.clear.frame(width: 40, height: 58)
                    Color.clear.frame(width: 40, height: 58)
                }
                .environment(\.horizontalSizeClass, sizeClass)
            )
            let size = host.sizeThatFits(in: CGSize(width: 360, height: 1000))
            XCTAssertEqual(size.width, 360, accuracy: 0.5)
            XCTAssertEqual(size.height, 58 + 12 + 0.5, accuracy: 0.5)
        }
    }
}
