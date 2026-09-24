#if os(tvOS)
import SwiftUI

struct TVExpandableSynopsis: View {
    let overview: String
    var compact = false
    @State private var showsDescription = false

    var body: some View {
        Button { showsDescription = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(overview)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(4)
                    .lineLimit(compact ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text("Read more")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVSynopsisButtonStyle())
        .accessibilityHint("Opens the full description")
        .fullScreenCover(isPresented: $showsDescription) {
            TVFullSynopsis(overview: overview)
                .presentationBackground(.clear)
        }
    }
}

private struct TVFullSynopsis: View {
    let overview: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedBlock: Int?
    @State private var contentHeight: CGFloat = 40

    private var blocks: [String] {
        var result: [String] = []
        for paragraph in overview.components(separatedBy: .newlines) where !paragraph.isEmpty {
            var block = ""
            for word in paragraph.split(separator: " ") {
                if block.count + word.count > 600, !block.isEmpty {
                    result.append(block)
                    block = ""
                }
                block += (block.isEmpty ? "" : " ") + word
            }
            if !block.isEmpty { result.append(block) }
        }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("Description")
                    .font(.system(size: 38, weight: .bold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            Text(block)
                                .font(.system(size: 26))
                                .lineSpacing(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(.white.opacity(focusedBlock == index ? 0.7 : 0), lineWidth: 2)
                                }
                                .focusable()
                                .focused($focusedBlock, equals: index)
                                .focusEffectDisabled()
                        }
                    }
                    .padding(2)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .frame(height: min(max(contentHeight, 40), 560))
                .scrollBounceBehavior(.basedOnSize)
                .defaultFocus($focusedBlock, 0)
            }
            .foregroundStyle(.white)
            .padding(32)
            .frame(width: TVDetailLayout.heroContentWidth + 64)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
        .onExitCommand { dismiss() }
    }
}

/// Keep the text on the editorial baseline and indicate focus with a ring only.
private struct TVSynopsisButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVSynopsisButtonStyleBody(configuration: configuration)
    }
}

private struct TVSynopsisButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
            }
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }
}
#endif
