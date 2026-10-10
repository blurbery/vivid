import SwiftUI

extension View {
    /// Presents a sheet on Vivid glass at every height. iOS 26 makes a sheet
    /// opaque once it reaches the system `.large` detent, so the tallest stop
    /// here is a custom detent just short of it. Sheets that open fully pass
    /// `startsTall`. Sheets over live video pass `overVideo` so older devices
    /// get the non-sampling player glass.
    @ViewBuilder
    func vividGlassSheet(startsTall: Bool = false, overVideo: Bool = false) -> some View {
        #if os(iOS)
        self
            .presentationBackground {
                if overVideo {
                    Color.clear.vividPlayerGlass(in: Rectangle())
                } else {
                    Color.clear.vividGlass(in: Rectangle())
                }
            }
            .presentationDetents(startsTall ? [.vividGlassTall] : [.medium, .vividGlassTall])
            .presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}

#if os(iOS)
extension PresentationDetent {
    static let vividGlassTall = Self.custom(VividGlassTallDetent.self)
}

private struct VividGlassTallDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        context.maxDetentValue * 0.98
    }
}
#endif

/// Glass X that closes a sheet, in place of a text Cancel, Close or Done.
/// Apple TV keeps its text button, which the remote's focus engine expects.
struct VividSheetCloseItem: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            #if os(tvOS)
            Button("Done", action: action)
            #else
            Button(action: action) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            #endif
        }
    }
}
