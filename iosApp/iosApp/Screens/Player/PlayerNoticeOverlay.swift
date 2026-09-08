import Foundation
import SwiftUI

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

struct PlayerNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let tone: PlayerNoticeTone
}

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
