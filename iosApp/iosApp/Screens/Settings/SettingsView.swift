import SwiftUI

/// App settings screen.
///
/// iOS: separate profile and settings sections with native grouped rows.
///
/// On tvOS this view delegates to ``TVSettingsView``, a root-menu Form
/// with drill-in sub-screens tuned for the 10-foot experience.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router
    @State private var showSignOutConfirm = false

    var body: some View {
        #if os(tvOS)
        TVSettingsView()
        #elseif os(iOS)
        iOSOverview
        #endif
    }

    #if os(iOS)
    private var iOSOverview: some View {
        IOSSettingsOverview(
            viewModel: viewModel,
            uiCustomization: uiCustomization,
            showSignOutConfirm: $showSignOutConfirm
        )
        .task {
            await viewModel.loadSettings()
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await TVSavedAccountStore.shared.captureCurrent()
                    if TVSavedAccountStore.shared.activeID != nil {
                        await TVSavedAccountStore.shared.signOut(router: router)
                    } else { router.signOutAndReset() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }
    #endif

}

