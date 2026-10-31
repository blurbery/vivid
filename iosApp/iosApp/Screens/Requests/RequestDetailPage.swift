import SwiftUI

/// A Seerr title with a button to request it, opened from Search.
struct RequestDetailView: View {
    @State private var model: RequestDetailModel

    init(mediaType: RequestMediaType, tmdbId: Int) {
        _model = State(initialValue: RequestDetailModel(mediaType: mediaType, tmdbId: tmdbId))
    }

    var body: some View {
        ZStack {
            if let detail = model.detail {
                RequestDetailContent(model: model, detail: detail)
            } else if let error = model.error {
                ErrorView(state: error, onRetry: { model.retry() })
                    .vividPageBackground()
            } else {
                LoadingView(usesPageBackground: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .vividPageBackground()
            }
        }
        #if !os(tvOS)
        .navigationTitle(model.detail?.title ?? "")
        .vividNavigationTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
        .vividNavigationBarSurfaceBackground()
        #endif
        .task { await model.load() }
        .onChange(of: RequestsEventBus.shared.latest) { _, record in
            guard let record else { return }
            model.handleBroadcast(record)
        }
    }
}

private struct RequestDetailContent: View {
    let model: RequestDetailModel
    let detail: RequestMediaDetail

    private var metaLine: String { RequestMetaLine.text(for: detail) }

    private var overview: String? {
        guard let overview = detail.overview, !overview.isEmpty else { return nil }
        return overview
    }

    var body: some View {
        #if os(tvOS)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                Spacer(minLength: 240)
                VStack(alignment: .leading, spacing: 18) {
                    Text(eyebrow)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Color.vividSecondaryText)
                    Text(detail.title)
                        .font(.system(size: 68, weight: .heavy))
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(2)
                    Text(metaLine)
                        .font(.vividCaption)
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(1)
                    if let overview {
                        Text(overview)
                            .font(.vividBody)
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(3)
                            .frame(maxWidth: 980, alignment: .leading)
                    }
                }
                HStack(spacing: 24) {
                    RequestPrimaryButton(model: model)
                    if let message = model.actionMessage {
                        Text(message)
                            .font(.vividCaption)
                            .foregroundStyle(Color.vividSecondaryText)
                    } else if model.primaryAction == .request {
                        Text("Reviewed by your server admin")
                            .font(.vividSmall)
                            .foregroundStyle(Color.vividSecondaryText.opacity(0.7))
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, 80)
        }
        .vividPageBackground()
        .background(alignment: .top) {
            backdrop
        }
        #else
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: VividTheme.padding) {
                hero
                VStack(alignment: .leading, spacing: VividTheme.padding) {
                    RequestPrimaryButton(model: model)
                    if let message = model.actionMessage {
                        Text(message)
                            .font(.vividCaption)
                            .foregroundStyle(Color.vividSecondaryText)
                            .frame(maxWidth: .infinity)
                    }
                    if let overview {
                        Text(overview)
                            .font(.vividBody)
                            .foregroundStyle(Color.vividSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, VividTheme.padding)
                .padding(.bottom, VividTheme.largePadding)
            }
        }
        .vividPageBackground()
        #endif
    }

    #if os(tvOS)
    private var eyebrow: String {
        var parts = [
            String(localized: "REQUEST", comment: "Eyebrow above a requestable title on Apple TV"),
            detail.mediaType.displayName.uppercased(),
        ]
        if detail.availability != .available {
            parts.append(String(localized: "NOT IN YOUR LIBRARY", comment: "Eyebrow above a requestable title on Apple TV"))
        }
        return parts.joined(separator: " · ")
    }

    private var backdrop: some View {
        ZStack {
            if let url = RequestArtworkURL.backdrop(detail.backdropPath) {
                AsyncImageView(url: url, contentMode: .fill)
            } else {
                Color.vividSurface
            }
            LinearGradient(
                colors: [Color.black.opacity(0.35), Color.black.opacity(0.72), Color.vividBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
    #else
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = RequestArtworkURL.backdrop(detail.backdropPath) {
                AsyncImageView(url: url, contentMode: .fill)
                    .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            colors: [.clear, Color.vividBackground.opacity(0.65), Color.vividBackground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            } else {
                Rectangle()
                    .fill(Color.vividSurfaceElevated)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
            }
            HStack(alignment: .bottom, spacing: VividTheme.padding) {
                if let url = RequestArtworkURL.poster(detail.posterPath) {
                    AsyncImageView(url: url, contentMode: .fill)
                        .frame(width: 96, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
                        .shadow(color: Color.black.opacity(0.5), radius: 12, y: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title)
                        .font(.vividTitle)
                        .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(2)
                    Text(metaLine)
                        .font(.vividCaption)
                        .foregroundStyle(Color.vividSecondaryText)
                        .lineLimit(2)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, VividTheme.padding)
            .offset(y: 48)
        }
        .padding(.bottom, 48)
    }
    #endif
}

/// The request page's main button. It stays one button while it moves from
/// request to requesting to the resulting state, so focus never jumps.
private struct RequestPrimaryButton: View {
    let model: RequestDetailModel

    #if os(tvOS)
    private let spacing: CGFloat = 16
    private let dotSize: CGFloat = 14
    private let font: Font = .system(size: 30, weight: .semibold)
    private let horizontalPadding: CGFloat = 44
    private let verticalPadding: CGFloat = 22
    #else
    private let spacing: CGFloat = 8
    private let dotSize: CGFloat = 8
    private let font: Font = .vividHeadline
    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 13
    #endif

    private var action: RequestPrimaryAction { model.primaryAction }
    private var isInteractive: Bool { action == .request }

    private var title: String {
        switch action {
        case .loading, .request:
            model.mediaType == .series ? String(localized: "Request Series") : String(localized: "Request Movie")
        case .submitting:
            String(localized: "Requesting…")
        case .status(let badge):
            Self.title(for: badge)
        }
    }

    private static func title(for badge: RequestBadge) -> String {
        switch badge {
        case .pending:
            String(localized: "Requested · Pending")
        case .onTheWay:
            String(localized: "On the way")
        case .inLibrary:
            String(localized: "In your library")
        case .needsAttention(let reason):
            if let copy = RequestReasonText.text(for: reason) {
                String(localized: "Declined · \(copy)")
            } else {
                String(localized: "Needs attention")
            }
        case .unavailable(let reason):
            RequestReasonText.text(for: reason) ?? String(localized: "Unavailable")
        }
    }

    var body: some View {
        Button {
            model.requestTapped()
        } label: {
            label
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(.borderless)
        .disabled(!isInteractive)
        #endif
        .accessibilityLabel(title)
        .animation(.easeOut(duration: 0.15), value: isInteractive)
    }

    private var label: some View {
        HStack(spacing: spacing) {
            icon
            Text(title)
                .fontWeight(.bold)
                .lineLimit(1)
        }
        .font(font)
        .foregroundStyle(isInteractive ? Color.vividBackground : Color.vividOnSurface)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        #if !os(tvOS)
        .frame(maxWidth: .infinity)
        #endif
        .background(Capsule().fill(isInteractive ? Color.vividOnSurface : Color.vividChromeRestingFill))
        .overlay(Capsule().stroke(isInteractive ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var icon: some View {
        switch action {
        case .loading, .request:
            Image(systemName: "plus")
        case .submitting:
            ProgressView()
                .controlSize(.small)
                .tint(Color.vividSecondaryText)
        case .status(let badge):
            Circle()
                .fill(badge.tint)
                .frame(width: dotSize, height: dotSize)
        }
    }
}
