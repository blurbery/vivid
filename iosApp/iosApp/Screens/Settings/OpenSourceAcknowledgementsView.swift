import Foundation
import SwiftUI

/// Open Source Licences: a list of what Vivid uses, with a page for each.
///
/// `OpenSourceLicenses/licences.json` is the only list. Licence bodies that
/// repeat byte for byte are stored once as shared texts; an entry's notice
/// keeps one marker line where its shared text was. The website's /licences
/// page is built from the same files, and scripts/tests/licence-texts-tests.py
/// proves every original file still rebuilds exactly.
enum OpenSourceAcknowledgements {
    struct SharedText: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let short: String
        let file: String
    }

    struct Entry: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let version: String?
        let licence: String?
        let notice: String?
        let text: String?

        /// Version and licence for the list, such as "8.0.1 · GPL 3.0 as built".
        var detail: String? {
            let parts = [version, licence].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private struct Manifest: Decodable {
        let marker: String
        let texts: [SharedText]
        let entries: [Entry]
    }

    private static let manifest: Manifest? = resourceURL(named: "licences", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }

    static var entries: [Entry] { manifest?.entries ?? [] }
    static var texts: [SharedText] { manifest?.texts ?? [] }
    static let onlineURL = VividAbout.website.appendingPathComponent("licences")
    static let sourceTitle = "Source for this build"

    enum Page: Hashable, Sendable {
        case source
        case entry(Entry)
        case text(SharedText)

        var title: String {
            switch self {
            case .source: return OpenSourceAcknowledgements.sourceTitle
            case .entry(let entry): return entry.name
            case .text(let text): return text.title
            }
        }

        var subtitle: String? {
            switch self {
            case .source: return VividAbout.sourceLabel
            case .entry(let entry): return entry.detail
            case .text: return nil
            }
        }
    }

    struct Block: Identifiable, Sendable {
        let id: Int
        /// Set on the first block of the licence text that follows a notice.
        let heading: String?
        let text: String
    }

    /// The page's notice, then its licence text, in blocks short enough to
    /// read as one focus stop on Apple TV.
    static func blocks(for page: Page) -> [Block] {
        var sections: [(heading: String?, text: String)] = []
        switch page {
        case .source:
            sections.append((nil, VividAbout.sourceNotice))
        case .entry(let entry):
            if let notice = entry.notice { sections.append((nil, contents(of: notice))) }
            if let id = entry.text, let shared = texts.first(where: { $0.id == id }) {
                sections.append((entry.notice == nil ? nil : shared.title, contents(of: shared.file)))
            }
        case .text(let shared):
            sections.append((nil, contents(of: shared.file)))
        }
        var result: [Block] = []
        for section in sections {
            for (index, text) in chunks(section.text).enumerated() {
                result.append(Block(id: result.count, heading: index == 0 ? section.heading : nil, text: text))
            }
        }
        return result
    }

    /// Splits text into blocks of about `limit` characters, at a blank line
    /// where there is one and otherwise at a line break. Blank lines at a
    /// split are dropped; the space between blocks takes their place.
    static func chunks(_ text: String, limit: Int = 1000) -> [String] {
        func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }
        func block(_ lines: ArraySlice<Substring>) -> String? {
            guard let first = lines.firstIndex(where: { !isBlank($0) }),
                  let last = lines.lastIndex(where: { !isBlank($0) }) else { return nil }
            return lines[first...last].joined(separator: "\n")
        }
        var result: [String] = []
        var lines: [Substring] = []
        var length = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if length + line.count > limit, lines.contains(where: { !isBlank($0) }) {
                let cut = lines.lastIndex(where: isBlank).flatMap { index in
                    lines[..<index].contains(where: { !isBlank($0) }) ? index : nil
                } ?? lines.count
                if let text = block(lines[..<cut]) { result.append(text) }
                lines = Array(lines[cut...])
                length = lines.reduce(0) { $0 + $1.count + 1 }
            }
            lines.append(line)
            length += line.count + 1
        }
        if let text = block(lines[...]) { result.append(text) }
        return result
    }

    private static func contents(of name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        guard let url = resourceURL(named: base, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled licence resource \(name) is unavailable."
        }
        // Some upstream files use CRLF; show them with plain line breaks.
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func resourceURL(named name: String, withExtension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "OpenSourceLicenses")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }
}

#if os(tvOS)
struct OpenSourceAcknowledgementsView: View {
    var body: some View { TVOpenSourceAcknowledgementsPage() }
}
#else
struct OpenSourceAcknowledgementsView: View {
    var body: some View {
        List {
            Text("Open Source Licences").font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.vividOnSurface)
                .settingsPageHeaderRow()
            Section {
                link(.source)
                ForEach(OpenSourceAcknowledgements.entries) { link(.entry($0)) }
            }
            Section {
                ForEach(OpenSourceAcknowledgements.texts) { link(.text($0)) }
            } header: { PhoneSettingsSectionHeader("Licence texts") }
            Section {
                Link(destination: OpenSourceAcknowledgements.onlineURL) {
                    HStack {
                        Text("View online")
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsListChrome().navigationTitle("")
    }

    private func link(_ page: OpenSourceAcknowledgements.Page) -> some View {
        NavigationLink { OpenSourceLicencePage(page: page) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).font(.body.weight(.medium))
                if let detail = page.subtitle {
                    Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OpenSourceLicencePage: View {
    let page: OpenSourceAcknowledgements.Page
    @State private var blocks: [OpenSourceAcknowledgements.Block] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(page.title).font(.system(size: 30, weight: .bold, design: .rounded))
                if let subtitle = page.subtitle {
                    Text(subtitle).foregroundStyle(.secondary).padding(.top, -16)
                }
                if blocks.isEmpty { ProgressView("Loading licence…") }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        if let heading = block.heading { Text(heading).font(.title3.bold()) }
                        Text(verbatim: block.text).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
            }
            .padding(24).frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }.vividBackground().navigationTitle("")
        .settingsNavigationChrome()
        .task {
            let page = page
            let loaded = await Task.detached(priority: .userInitiated) { OpenSourceAcknowledgements.blocks(for: page) }.value
            guard !Task.isCancelled else { return }
            blocks = loaded
        }
    }
}
#endif

#if os(tvOS)
struct TVOpenSourceAcknowledgementsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVSettingsPageHeader(title: "Open Source Licences")
                TVSettingsGroup {
                    row(.source)
                    ForEach(OpenSourceAcknowledgements.entries) { row(.entry($0)) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionHeader("LICENCE TEXTS", topInset: 0)
                    TVSettingsGroup {
                        ForEach(OpenSourceAcknowledgements.texts) { row(.text($0)) }
                    }
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth).padding(24).frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
    }

    private func row(_ page: OpenSourceAcknowledgements.Page) -> some View {
        NavigationLink { TVOpenSourceLicencePage(page: page) } label: {
            TVSettingsRowLabel(title: page.title, detail: page.subtitle)
        }.buttonStyle(TVSettingsPaneRowStyle())
    }
}

/// One entry's notice and licence text. Text is not focusable on tvOS, so
/// each block is a focus stop the remote scrolls through.
struct TVOpenSourceLicencePage: View {
    let page: OpenSourceAcknowledgements.Page
    @Environment(\.dismiss) private var dismiss
    @State private var blocks: [OpenSourceAcknowledgements.Block] = []
    @FocusState private var focusedBlock: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 24) {
                TVSettingsPageHeader(title: page.title, subtitle: page.subtitle)
                if blocks.isEmpty {
                    ProgressView("Loading licence…")
                }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        if let heading = block.heading {
                            Text(heading).font(.system(size: 27, weight: .semibold))
                        }
                        Text(verbatim: block.text)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(focusedBlock == block.id ? 0.85 : 0), lineWidth: 2)
                    }
                    .focusable()
                    .focused($focusedBlock, equals: block.id)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focusedBlock, 0)
        .onExitCommand { dismiss() }
        .task {
            let page = page
            let loaded = await Task.detached(priority: .userInitiated) { OpenSourceAcknowledgements.blocks(for: page) }.value
            guard !Task.isCancelled else { return }
            blocks = loaded
        }
    }
}
#endif
