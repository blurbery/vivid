import SwiftUI

/// The bundled open source licence list: `OpenSourceLicenses/licences.json`
/// and the text files beside it.
private struct LicenceCatalogue: Decodable {
    struct SharedText: Decodable, Hashable, Identifiable {
        let id: String
        let title: String
        let short: String?
        let file: String
    }

    struct Entry: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
        let version: String?
        let licence: String?
        let notice: String?
        let text: String?

        /// Version and licence, such as "1.4 · MIT".
        var detail: String? {
            let parts = [version, licence].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    let marker: String?
    let texts: [SharedText]
    let entries: [Entry]

    static let bundled: LicenceCatalogue = {
        let folder = Bundle.main.url(forResource: "licences", withExtension: "json", subdirectory: "OpenSourceLicenses")
        guard let url = folder ?? Bundle.main.url(forResource: "licences", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalogue = try? JSONDecoder().decode(LicenceCatalogue.self, from: data) else {
            return LicenceCatalogue(marker: nil, texts: [], entries: [])
        }
        return catalogue
    }()

    func sharedText(_ id: String?) -> SharedText? {
        texts.first { $0.id == id }
    }

    /// A bundled file's text, or a note that it's missing.
    static func contents(of file: String) -> String {
        let name = (file as NSString).deletingPathExtension
        let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "OpenSourceLicenses")
            ?? Bundle.main.url(forResource: name, withExtension: "txt")
        guard let url, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return String(localized: "The bundled licence resource \(file) is unavailable.")
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}

/// One page of licence text: this build's source, a component, or a
/// licence text several components share.
private enum LicencePage: Hashable {
    case source
    case entry(LicenceCatalogue.Entry)
    case text(LicenceCatalogue.SharedText)

    struct Block: Identifiable {
        let id: Int
        let heading: String?
        let text: String
    }

    var title: String {
        switch self {
        case .source: String(localized: "Source for this build")
        case .entry(let entry): entry.name
        case .text(let text): text.title
        }
    }

    var subtitle: String? {
        switch self {
        case .source: VividAbout.sourceLabel
        case .entry(let entry): entry.detail
        case .text: nil
        }
    }

    /// The page's text in blocks small enough to draw quickly.
    func blocks() -> [Block] {
        var sections: [(heading: String?, text: String)] = []
        switch self {
        case .source:
            sections = [(nil, VividAbout.sourceNotice)]
        case .entry(let entry):
            if let notice = entry.notice {
                sections.append((nil, LicenceCatalogue.contents(of: notice)))
            }
            if let shared = LicenceCatalogue.bundled.sharedText(entry.text) {
                sections.append((entry.notice == nil ? nil : shared.title, LicenceCatalogue.contents(of: shared.file)))
            }
        case .text(let text):
            sections = [(nil, LicenceCatalogue.contents(of: text.file))]
        }
        var blocks: [Block] = []
        for section in sections {
            for (index, text) in Self.split(section.text).enumerated() {
                blocks.append(Block(id: blocks.count, heading: index == 0 ? section.heading : nil, text: text))
            }
        }
        return blocks
    }

    /// Splits text into blocks of about `limit` characters, breaking at the
    /// last blank line that fits. A single longer line stays whole.
    static func split(_ text: String, limit: Int = 1000) -> [String] {
        func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }
        var blocks: [String] = []
        func emit(_ lines: ArraySlice<String>) {
            guard let first = lines.firstIndex(where: { !isBlank($0) }),
                  let last = lines.lastIndex(where: { !isBlank($0) }) else { return }
            blocks.append(lines[first...last].joined(separator: "\n"))
        }
        var current: [String] = []
        var size = 0
        for line in text.components(separatedBy: "\n") {
            if size + line.count > limit, let firstText = current.firstIndex(where: { !isBlank($0) }) {
                if let cut = current.lastIndex(where: isBlank), cut > firstText {
                    emit(current[..<cut])
                    current = Array(current[cut...])
                    size = current.reduce(0) { $0 + $1.count + 1 }
                } else {
                    emit(current[...])
                    current = []
                    size = 0
                }
            }
            current.append(line)
            size += line.count + 1
        }
        emit(current[...])
        return blocks
    }

    static func loadBlocks(for page: LicencePage) async -> [Block] {
        await Task.detached(priority: .userInitiated) { page.blocks() }.value
    }
}

#if os(iOS)
/// Settings > About > Open Source Licences.
struct OpenSourceAcknowledgementsView: View {
    private let catalogue = LicenceCatalogue.bundled

    var body: some View {
        List {
            Text("Open Source Licences")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.vividOnSurface)
                .settingsPageHeaderRow()
            Section {
                row(.source)
                ForEach(catalogue.entries) { row(.entry($0)) }
            }
            Section {
                ForEach(catalogue.texts) { row(.text($0)) }
            } header: { PhoneSettingsSectionHeader("Licence texts") }
            Section {
                Link(destination: VividAbout.website.appendingPathComponent("licences")) {
                    HStack {
                        Text("View online")
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsListChrome()
        .navigationTitle("")
    }

    private func row(_ page: LicencePage) -> some View {
        NavigationLink { PhoneLicencePage(page: page) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).font(.body.weight(.medium))
                if let subtitle = page.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PhoneLicencePage: View {
    let page: LicencePage
    @State private var blocks: [LicencePage.Block] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(page.title).font(.system(size: 30, weight: .bold, design: .rounded))
                subtitle.padding(.top, -16)
                if blocks.isEmpty {
                    ProgressView("Loading licence…")
                }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        if let heading = block.heading {
                            Text(heading).font(.title3.bold())
                        }
                        Text(block.text).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .vividBackground()
        .navigationTitle("")
        .settingsNavigationChrome()
        .task {
            let loaded = await LicencePage.loadBlocks(for: page)
            if !Task.isCancelled { blocks = loaded }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let text = page.subtitle {
            if page == .source, let url = VividAbout.sourceURL {
                Link(text, destination: url)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            } else {
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
#endif

#if os(tvOS)
/// Settings > About > Open Source Licences on Apple TV.
struct TVOpenSourceAcknowledgementsPage: View {
    private let catalogue = LicenceCatalogue.bundled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(28)) {
                TVSettingsPageHeader(title: "Open Source Licences")
                TVSettingsGroup {
                    row(.source)
                    ForEach(catalogue.entries) { row(.entry($0)) }
                }
                VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                    TVSettingsSectionHeader("LICENCE TEXTS", topInset: 0)
                    TVSettingsGroup {
                        ForEach(catalogue.texts) { row(.text($0)) }
                    }
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth)
            .padding(TVSettingsLayout.scaled(24))
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
    }

    private func row(_ page: LicencePage) -> some View {
        NavigationLink { TVLicencePage(page: page) } label: {
            TVSettingsRowLabel(title: Text(page.title), detail: page.subtitle.map { Text($0) })
        }
        .buttonStyle(TVSettingsPaneRowStyle())
    }
}

private struct TVLicencePage: View {
    let page: LicencePage
    @State private var blocks: [LicencePage.Block] = []
    @FocusState private var focusedBlock: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: TVSettingsLayout.scaled(24)) {
                TVSettingsPageHeader(title: page.title, subtitle: page.subtitle)
                if blocks.isEmpty {
                    ProgressView("Loading licence…")
                }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(12)) {
                        if let heading = block.heading {
                            Text(heading).font(.tvSettings(27, weight: .semibold))
                        }
                        Text(block.text)
                            .font(.tvSettings(22))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TVSettingsLayout.scaled(18))
                    .overlay {
                        RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(14))
                            .strokeBorder(.white.opacity(focusedBlock == block.id ? 0.85 : 0), lineWidth: 2)
                    }
                    .focusable()
                    .focused($focusedBlock, equals: block.id)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth)
            .padding(.horizontal, TVSettingsLayout.scaled(24))
            .padding(.vertical, TVSettingsLayout.scaled(48))
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focusedBlock, 0)
        .onExitCommand { dismiss() }
        .task {
            let loaded = await LicencePage.loadBlocks(for: page)
            if !Task.isCancelled { blocks = loaded }
        }
    }
}
#endif

/// Settings > About > Acknowledgements: the services Vivid relies on.
struct ServiceAcknowledgementsView: View {
    private struct Credit: Identifiable {
        let id: String
        let image: String
        let isSymbol: Bool
        let thanks: String
        let website: String
    }

    private var credits: [Credit] {
        [
            Credit(id: "TheIntroDB", image: "AcknowledgementTheIntroDB", isSymbol: false,
                   thanks: String(localized: "Thank you for community intro, recap and credits timestamps."),
                   website: "theintrodb.org"),
            Credit(id: "IntroDB", image: "AcknowledgementIntroDB", isSymbol: false,
                   thanks: String(localized: "Thank you for helping more episodes offer skip prompts."),
                   website: "introdb.app"),
            // TMDB's required notice stays in English.
            Credit(id: "TMDB", image: "TMDbAttributionLogo", isSymbol: false,
                   thanks: String(localized: "Thank you for the movie and TV metadata and artwork.")
                       + " This product uses the TMDB API but is not endorsed or certified by TMDB.",
                   website: "themoviedb.org"),
            Credit(id: "TVmaze", image: "calendar", isSymbol: true,
                   thanks: String(localized: "Thank you for the episode air times in the Calendar, used under CC BY-SA 4.0."),
                   website: "tvmaze.com"),
        ]
    }

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(16)) {
                Text("Acknowledgements").font(.tvSettings(42, weight: .bold))
                Text("With thanks to the projects and communities that help make Vivid possible.")
                    .font(.tvSettings(20))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TVSettingsLayout.scaled(24)), count: 2),
                          spacing: TVSettingsLayout.scaled(16)) {
                    ForEach(credits) { card($0) }
                }
                .focusSection()
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth)
            .padding(TVSettingsLayout.scaled(20))
            .frame(maxWidth: .infinity)
        }
        .vividBackground()
        .navigationTitle("")
        .tvSettingsPageSurface()
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Acknowledgements").font(.largeTitle.bold())
                Text("With thanks to the projects and communities that help make Vivid possible.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], spacing: 28) {
                    ForEach(credits) { card($0) }
                }
            }
            .padding(32)
            .frame(maxWidth: 1160)
            .frame(maxWidth: .infinity)
        }
        .vividBackground()
        .navigationTitle("")
        .settingsNavigationChrome()
        #endif
    }

    @ViewBuilder
    private func artwork(_ credit: Credit) -> some View {
        if credit.isSymbol {
            Image(systemName: credit.image).resizable().scaledToFit().padding(12)
        } else {
            Image(credit.image).resizable().scaledToFit()
        }
    }

    private func card(_ credit: Credit) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        #if os(tvOS)
        return VStack(spacing: TVSettingsLayout.scaled(10)) {
            artwork(credit)
                .frame(width: TVSettingsLayout.scaled(120), height: TVSettingsLayout.scaled(56))
                .accessibilityHidden(true)
            Text(verbatim: credit.id).font(.tvSettings(26, weight: .bold))
            Text(credit.thanks)
                .font(.tvSettings(19))
                .foregroundStyle(.secondary)
                .frame(height: TVSettingsLayout.scaled(114), alignment: .top)
            Text(verbatim: credit.website)
                .font(.tvSettings(17))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .multilineTextAlignment(.center)
        .padding(TVSettingsLayout.scaled(16))
        .frame(maxWidth: .infinity)
        .frame(height: TVSettingsLayout.scaled(300))
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .focusable()
        .accessibilityElement(children: .combine)
        #else
        return VStack(spacing: 14) {
            artwork(credit)
                .frame(width: 120, height: 80)
                .accessibilityHidden(true)
            Text(verbatim: credit.id).font(.title3.bold())
            Text(credit.thanks)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: credit.website)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 270)
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        #endif
    }
}
