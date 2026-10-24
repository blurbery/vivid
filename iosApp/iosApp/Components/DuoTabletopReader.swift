#if os(iOS)
import SwiftUI
import UIKit

/// The iPhone Duo half folded in portrait, like a laptop: the inner screen's
/// crease runs across it, and the lower half usually rests on a table.
struct DuoTabletop: Equatable {
    /// The band iOS reserves around the crease, in the reading view's
    /// coordinates. Content goes above `crease.minY` or below `crease.maxY`.
    let crease: CGRect
}

extension View {
    /// Reports whether the iPhone Duo is half folded with its crease across
    /// this view, and where the crease is. Place it on a view that fills the
    /// screen. Always nil off the Duo and when built without the iOS 27.1
    /// SDK, which first has the hinge and crease APIs.
    func onDuoTabletopChange(_ action: @escaping (DuoTabletop?) -> Void) -> some View {
        background {
            if PhoneDuo.isDuo {
                DuoTabletopReader(onChange: action)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Keeps a full-screen layer above the crease while the Duo is half
    /// folded. Otherwise leaves it as it is.
    @ViewBuilder
    func duoTabletopTopHalf(_ tabletop: DuoTabletop?) -> some View {
        if let tabletop {
            frame(height: tabletop.crease.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        } else {
            self
        }
    }
}

private struct DuoTabletopReader: UIViewRepresentable {
    let onChange: (DuoTabletop?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((DuoTabletop?) -> Void)?
        private var isPartiallyOpen = false
        private var reported: DuoTabletop??

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            #if canImport(UIKit, _version: 9127.0.85)
            if #available(iOS 27.1, *) {
                addInteraction(UIHingeInteraction { [weak self] _, update in
                    self?.isPartiallyOpen = update.hinge?.status == .partiallyOpen
                    self?.report()
                })
            }
            #endif
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            let tabletop = currentTabletop()
            guard reported != .some(tabletop) else { return }
            reported = .some(tabletop)
            onChange?(tabletop)
        }

        private func currentTabletop() -> DuoTabletop? {
            #if canImport(UIKit, _version: 9127.0.85)
            if #available(iOS 27.1, *), isPartiallyOpen {
                // A crease running across the view means portrait. Half
                // folded in landscape, it runs down the middle like a book.
                // The first hinge update can arrive before iOS marks the
                // crease active, so take it while the hinge is half open.
                let crease = reservedRegions(kind: .division, options: .includeInactive)
                    .first { $0.frame.width > $0.frame.height }
                return crease.map { DuoTabletop(crease: $0.frame) }
            }
            #endif
            return nil
        }
    }
}
#endif
