import SwiftUI

@main
struct VividApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(VividAppDelegate.self) private var appDelegate
    #endif

    init() {
        FreshInstallLocalData.prepare()
        #if os(tvOS)
        TVFrameHitchMonitor.installIfRequested()
        #endif
        PosterImageCache.install()
        LaunchTimeline.recordProcessStart()
        AppHealthMonitor.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
