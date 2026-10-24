#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Keeps `DuoStatusArea` up to date as widgets are added to or removed
    /// from the iPhone Duo's status bar. Place it once, on the root view.
    func readsDuoStatusArea() -> some View {
        background {
            if PhoneDuo.isDuo {
                DuoStatusAreaInstaller()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct DuoStatusAreaInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ view: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { DuoStatusAreaView.install(in: window) }
        }
    }
}

/// Measures the band at the top of the Duo's side strip, or its top corner in
/// portrait, from the bar layout region iOS 27.1 offers for each side. It
/// sits behind everything in the window, so it keeps measuring while a
/// detail page, a pushed page or the player covers the tab view, and a
/// fold keeps the same window.
final class DuoStatusAreaView: UIView {
    private var guides: [UILayoutGuide] = []

    static func install(in window: UIWindow) {
        guard !window.subviews.contains(where: { $0 is DuoStatusAreaView }) else { return }
        let view = DuoStatusAreaView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(view, at: 0)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            for edge in [NSDirectionalRectEdge.leading, .trailing] {
                let guide = layoutGuide(for: .bar(onEdge: edge, extent: 72))
                // Something pinned to the guide makes UIKit lay this view
                // out again whenever the band changes.
                let marker = UIView()
                marker.translatesAutoresizingMaskIntoConstraints = false
                addSubview(marker)
                NSLayoutConstraint.activate([
                    marker.topAnchor.constraint(equalTo: guide.topAnchor),
                    marker.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                    marker.widthAnchor.constraint(equalToConstant: 0),
                    marker.heightAnchor.constraint(equalToConstant: 0),
                ])
                guides.append(guide)
            }
        }
        #endif
        // Widgets are usually changed outside the app.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIScene.didActivateNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sceneDidActivate() {
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let bandBottom = guides.map(\.layoutFrame.minY).max() else { return }
        DuoStatusArea.shared.update(bandBottom: bandBottom, screen: bounds.size)
    }
}
#endif
