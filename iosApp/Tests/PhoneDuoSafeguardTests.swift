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

    func testActionMetricsKeepThePhoneSizes() throws {
        try skipOnDuo()
        let metrics = PhoneLabeledActionMetrics(sharesRow: false)
        XCTAssertEqual(metrics.circle, 42)
        XCTAssertEqual(metrics.iconSize, 19)
        XCTAssertNil(metrics.slotWidth)
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

    /// The named actions spread across the full width with the rule under
    /// them, as on every iPhone before the Duo work.
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
