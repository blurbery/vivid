#if os(tvOS)
import SwiftUI

struct TVExpandableSynopsis: View {
    let overview: String
    @State private var showsDescription = false

    var body: some View {
        Button { showsDescription = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(overview)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(4)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Read more")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: TVDetailLayout.heroContentWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVSynopsisButtonStyle())
        .accessibilityHint("Opens the full description")
        .fullScreenCover(isPresented: $showsDescription) {
            TVFullSynopsis(overview: overview)
        }
    }
}

private struct TVFullSynopsis: View {
    let overview: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedBlock: Int?

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
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("Description")
                    .font(.system(size: 38, weight: .bold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            Text(block)
                                .font(.system(size: 26))
                                .lineSpacing(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .background(.white.opacity(focusedBlock == index ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 14))
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
                }
                .defaultFocus($focusedBlock, 0)
            }
            .foregroundStyle(.white)
            .padding(40)
            .frame(width: 1160, height: 780)
            .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 24))
        }
        .onExitCommand { dismiss() }
    }
}

/// No chrome at rest; on focus a faint fill cue so the user knows it's
/// actionable. Suppresses the system halo (matches the page idiom).
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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius, style: .continuous)
                    .fill(Color.vividSurfaceElevated.opacity(isFocused ? 0.55 : 0))
            )
            .padding(.horizontal, -20)
            .padding(.vertical, -14)
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }
}
#endif
