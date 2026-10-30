import SwiftUI
#if os(iOS)
import UIKit
#endif

enum VividNavigationTitleDisplayMode {
    case inline
    case large
}

/// Navigation bar, list and search settings that only exist on iPhone and
/// iPad. Apple TV keeps each view as it is unless noted.
extension View {
    func vividNavigationTitleDisplayMode(_ mode: VividNavigationTitleDisplayMode) -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(mode == .large ? .large : .inline)
        #else
        self
        #endif
    }

    func vividScrollContentBackgroundHidden() -> some View {
        #if os(iOS)
        scrollContentBackground(.hidden)
        #else
        self
        #endif
    }

    func vividStatusBarHidden() -> some View {
        #if os(iOS)
        statusBarHidden(true)
        #else
        self
        #endif
    }

    func vividToolbarColorSchemeDark() -> some View {
        #if os(iOS)
        toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    func vividNavigationBarSurfaceBackground() -> some View {
        #if os(iOS)
        toolbarBackground(Color.vividSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    func vividNavigationBarBackgroundHidden() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Inset grouped on iPhone and iPad, plain on Apple TV.
    func vividGroupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.plain)
        #endif
    }

    /// A search field that stays visible under the title. On iPhone and iPad
    /// it has no Cancel button and doesn't dim the page while searching.
    func vividSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .background {
                SearchControllerTuner()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }

    func vividResumePlaybackAlert(
        isPresented: Binding<Bool>,
        stoppedAt timestamp: String,
        onResume: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) -> some View {
        alert("Continue Watching?", isPresented: isPresented) {
            Button("Resume", action: onResume)
            Button("Play from Beginning", action: onRestart)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You stopped at \(timestamp).")
        }
    }
}

#if os(iOS)
/// Hides the soft edge iOS 26 draws under the navigation bar.
struct MobileTopScrollEdgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// Finds the search controller `searchable` installed for this screen and
/// keeps its Cancel button and background dimming off.
private struct SearchControllerTuner: UIViewRepresentable {
    func makeUIView(context: Context) -> SearchControllerTunerView {
        SearchControllerTunerView()
    }

    func updateUIView(_ view: SearchControllerTunerView, context: Context) {}
}

private final class SearchControllerTunerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // The search controller is attached after the view joins the window.
        DispatchQueue.main.async { [weak self] in
            self?.tuneSearchController()
        }
    }

    private func tuneSearchController() {
        guard let owner = searchOwner, let search = owner.navigationItem.searchController else { return }
        owner.definesPresentationContext = true
        owner.navigationController?.definesPresentationContext = true
        search.obscuresBackgroundDuringPresentation = false
        search.automaticallyShowsCancelButton = false
        search.searchBar.setShowsCancelButton(false, animated: false)
    }

    /// The nearest view controller above this view that has a search controller.
    private var searchOwner: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController, controller.navigationItem.searchController != nil {
                return controller
            }
            responder = current.next
        }
        return nil
    }
}
#endif

#if os(tvOS)
extension View {
    /// Prefers default focus in `namespace` when asked. Without a namespace
    /// the view is left as it is.
    @ViewBuilder
    func applyDefaultFocusIfNeeded(_ isPreferred: Bool, namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(isPreferred, in: namespace)
        } else {
            self
        }
    }
}
#endif
