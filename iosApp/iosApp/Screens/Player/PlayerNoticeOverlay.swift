import Foundation
import SwiftUI

/// Whether a player notice informs or warns, which sets its accent colour.
enum PlayerNoticeTone {
    case info
    case warning

    var accentColor: Color {
        switch self {
        case .info:
            return .vividPrimary
        case .warning:
            return .vividWarning
        }
    }
}

/// A short message shown at the top of the player, such as a command from
/// another device or a Picture in Picture start that failed.
struct PlayerNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let tone: PlayerNoticeTone
}

/// A glass banner at the top of the player for a `PlayerNotice`. It ignores
/// touches and reads as one element to VoiceOver.
struct PlayerNoticeOverlay: View {
    let notice: PlayerNotice

    var body: some View {
        HStack(spacing: VividTheme.spacing) {
            Circle()
                .fill(notice.tone.accentColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: VividTheme.smallPadding) {
                Text(notice.title)
                    .font(.vividSubheadline)
                    .foregroundColor(.vividOnSurface)

                Text(notice.message)
                    .font(.vividBody)
                    .foregroundColor(.vividSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VividTheme.padding)
        .padding(.vertical, VividTheme.spacing)
        .frame(maxWidth: 720)
        .vividPlayerGlass(
            in: RoundedRectangle(
                cornerRadius: VividTheme.cardCornerRadius,
                style: .continuous
            ),
            tint: notice.tone.accentColor.opacity(0.28)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .padding(.horizontal, VividTheme.safePadding)
        .padding(.top, VividTheme.safePadding)
        .transition(
            .move(edge: .top)
            .combined(with: .opacity)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notice.title). \(notice.message)")
    }
}
