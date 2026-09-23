#if !os(tvOS)
import SwiftUI

// MARK: - Primary play

/// Solid-white capsule play button. Phone-sized — comfortable 52pt
/// touch target with the play icon and label sitting inline.
///
/// `fullWidth` lets the button expand to its container — used in the
/// Apple-TV-style centered hero where Play is the dominant CTA.
struct PhonePrimaryPillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var fullWidth: Bool = false
    var resumeProgress: ResumePresentation? = nil

    var body: some View {
        Button {
            #if DEBUG && os(iOS)
            DiagTrace.breadcrumb(.essential, category: .focus, tag: "PlayButton", message: "primary button action received")
            #endif
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                if let resumeProgress {
                    ResumeButtonProgressLabel(progress: resumeProgress)
                        .font(.system(size: 17, weight: .semibold))
                } else {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 24 : 24)
            .frame(height: 52)
            .vividGlass(in: Capsule(), tint: .black.opacity(0.26), interactive: true)
            .overlay { Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.14), .white.opacity(0.38)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

#endif
