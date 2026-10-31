#if os(tvOS)
import SwiftUI

/// Keeps the text where it is and shows focus with a ring only: no fill,
/// lift or shadow.
struct TVSynopsisButtonStyle: ButtonStyle {
    init() {}

    func makeBody(configuration: Configuration) -> some View {
        TVSynopsisButtonBody(label: configuration.label)
    }
}

private struct TVSynopsisButtonBody: View {
    let label: ButtonStyleConfiguration.Label

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        label
            .overlay {
                RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
            }
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }
}

/// The hero's synopsis. Selecting it opens the whole description.
struct TVDetailSynopsisButton: View {
    let overview: String
    let isCompact: Bool
    let isEnabled: Bool
    var focus: FocusState<TVDetailHeroFocus?>.Binding

    @State private var showsFullText = false

    var body: some View {
        Button {
            showsFullText = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: overview)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineSpacing(4)
                    .lineLimit(isCompact ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if !isCompact {
                    Text("Read more")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
            .frame(maxWidth: 750, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVSynopsisButtonStyle())
        .disabled(!isEnabled)
        .focused(focus, equals: .synopsis)
        .accessibilityHint(Text("Opens the full description"))
        .fullScreenCover(isPresented: $showsFullText) {
            TVFullSynopsis(overview: overview)
                .presentationBackground(.clear)
        }
    }
}

/// The whole description on a glass panel, split into focusable blocks so a
/// long text can be scrolled with the remote. Menu closes it.
struct TVFullSynopsis: View {
    let overview: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedBlock: Int?
    @State private var contentHeight: CGFloat = 40

    init(overview: String, title: String = String(localized: "Description")) {
        self.overview = overview
        self.title = title
    }

    var body: some View {
        let blocks = Self.blocks(of: overview)
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: title)
                    .font(.system(size: 38, weight: .bold))

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            TVFullSynopsisBlock(text: block, isFocused: focusedBlock == index)
                                .focused($focusedBlock, equals: index)
                        }
                    }
                    .padding(2)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(contentHeight, 40), 560))
                .defaultFocus($focusedBlock, 0)
            }
            .foregroundStyle(.white)
            .padding(32)
            .frame(width: 814)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
        .onExitCommand {
            dismiss()
        }
    }

    /// Splits the text at line breaks, then gathers each line's words into
    /// blocks of at most about 600 characters.
    static func blocks(of text: String) -> [String] {
        var blocks: [String] = []
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        for line in lines {
            var block = ""
            for word in line.split(separator: " ", omittingEmptySubsequences: true) {
                if !block.isEmpty, block.count + word.count > 600 {
                    blocks.append(block)
                    block = ""
                }
                block += block.isEmpty ? String(word) : " " + word
            }
            if !block.isEmpty {
                blocks.append(block)
            }
        }
        return blocks
    }
}

private struct TVFullSynopsisBlock: View {
    let text: String
    let isFocused: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 26))
            .lineSpacing(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 2)
                }
            }
            .focusable()
            .focusEffectDisabled()
    }
}
#endif
