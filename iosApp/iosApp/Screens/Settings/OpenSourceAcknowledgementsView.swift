import Foundation
import SwiftUI

enum OpenSourceAcknowledgements {
    struct Resource: Sendable {
        let title: String
        let name: String
    }

    static let resources: [Resource] = [
        Resource(title: "Overview and provenance", name: "README"),
        Resource(title: "Vivid and VividKit: GPLv3", name: "Vivid-GPL-3.0"),
        Resource(title: "Vivid: Apple distribution permission", name: "Vivid-Apple-Distribution"),
        Resource(title: "Earlier Apache-licensed code", name: "Vivid-Apache-2.0"),
        Resource(title: "AetherEngine: LGPLv3 with Apple exception", name: "AetherEngine-LGPL-3.0"),
        Resource(title: "LibDovi: MIT", name: "LibDovi-MIT"),
        Resource(title: "FFmpegBuild and FFmpeg: LGPL 2.1", name: "FFmpegBuild-LGPL-2.1"),
        Resource(title: "dav1d: BSD 2-Clause", name: "dav1d-BSD-2-Clause"),
        Resource(title: "zimg: WTFPL version 2", name: "zimg-WTFPL"),
        Resource(title: "libzvbi ure.c: MIT", name: "libzvbi-ure-MIT"),
        Resource(title: "libass: ISC", name: "libass-ISC"),
        Resource(title: "FriBidi: LGPL 2.1", name: "FriBidi-LGPL-2.1"),
        Resource(title: "FreeType: FreeType License", name: "FreeType-FTL"),
        Resource(title: "HarfBuzz: MIT", name: "HarfBuzz-MIT"),
        Resource(title: "ThumbHash decoder: MIT", name: "ThumbHash-MIT"),
    ]

    static let text: String = resources.map { resource in
        let body: String
        if let url = resourceURL(named: resource.name),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            body = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = "The bundled license resource \(resource.name).txt is unavailable."
        }

        return "\(resource.title)\n\(String(repeating: "=", count: resource.title.count))\n\n\(body)"
    }
    .joined(separator: "\n\n\n")

    struct Block: Identifiable, Sendable {
        let id: Int
        let title: String
        let text: String
    }

    // Cached once, and first accessed from a utility task by the TV page.
    static let blocks: [Block] = {
        var result: [Block] = []
        for resource in resources {
            let contents = resourceURL(named: resource.name)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? "The bundled license resource \(resource.name).txt is unavailable."
            var paragraphs: [String] = []
            var count = 0
            var continued = false
            func appendBlock() {
                guard !paragraphs.isEmpty else { return }
                result.append(Block(id: result.count,
                                    title: resource.title + (continued ? " (continued)" : ""),
                                    text: paragraphs.joined(separator: "\n\n")))
                paragraphs.removeAll()
                count = 0
                continued = true
            }
            for paragraph in contents.components(separatedBy: "\n\n") {
                if count + paragraph.count > 1000 { appendBlock() }
                paragraphs.append(paragraph)
                count += paragraph.count + 2
            }
            appendBlock()
        }
        return result
    }()

    private static func resourceURL(named name: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "OpenSourceLicenses"
        ) ?? Bundle.main.url(forResource: name, withExtension: "txt")
    }
}

struct OpenSourceAcknowledgementsView: View {
    @State private var blocks: [OpenSourceAcknowledgements.Block] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Open Source Licences").font(.system(size: 30, weight: .bold, design: .rounded))
                if blocks.isEmpty { ProgressView("Loading licences…") }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(block.title).font(.title3.bold())
                        Text(verbatim: block.text).foregroundStyle(.secondary)
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
            }
            #if os(tvOS)
            .frame(maxWidth: TVSettingsLayout.contentWidth)
            .padding(24)
            #else
            .padding(24).frame(maxWidth: 760)
            #endif
            .frame(maxWidth: .infinity)
        }.vividBackground().navigationTitle("")
        #if !os(tvOS)
        .settingsNavigationChrome()
        #endif
        .task {
            let loaded = await Task.detached(priority: .utility) { OpenSourceAcknowledgements.blocks }.value
            guard !Task.isCancelled else { return }
            blocks = loaded
        }
    }
}

#if os(tvOS)
struct TVOpenSourceAcknowledgementsOverlay: View {
    let dismiss: () -> Void
    @State private var blocks: [OpenSourceAcknowledgements.Block] = []
    @FocusState private var focusedBlock: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 24) {
                TVSettingsPageHeader(title: "Open Source Licences")
                if blocks.isEmpty {
                    ProgressView("Loading licences…")
                }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(block.title).font(.system(size: 27, weight: .semibold))
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
        .onExitCommand(perform: dismiss)
        .task {
            let loaded = await Task.detached(priority: .utility) { OpenSourceAcknowledgements.blocks }.value
            guard !Task.isCancelled else { return }
            blocks = loaded
        }
    }
}
#endif
