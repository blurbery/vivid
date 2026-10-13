import Foundation
import SwiftUI

enum OpenSourceAcknowledgements {
    struct Resource: Sendable {
        let title: String
        let name: String
    }

    // Shown in this order. Keep it matched to THIRD_PARTY_NOTICES.md and the
    // .txt files in iosApp/Resources/OpenSourceLicenses.
    static let resources: [Resource] = [
        Resource(title: "Overview and provenance", name: "README"),
        Resource(title: "Vivid: GPLv3", name: "Vivid-GPL-3.0"),
        Resource(title: "Vivid: Apple distribution permission", name: "Vivid-Apple-Distribution"),
        Resource(title: "Earlier Apache-licensed code", name: "Vivid-Apache-2.0"),
        Resource(title: "Apple media bridge (Plezy): GPL 3.0", name: "Plezy-GPL-3.0"),
        Resource(title: "mpv: GPL 2.0 or later", name: "mpv-GPL-2.0-or-later"),
        Resource(title: "FFmpeg: GPL 3.0 or later", name: "FFmpeg-GPL-3.0-or-later"),
        Resource(title: "libass: ISC", name: "libass-ISC"),
        Resource(title: "FreeType: FreeType License", name: "FreeType-FTL"),
        Resource(title: "FriBidi: LGPL 2.1", name: "FriBidi-LGPL-2.1"),
        Resource(title: "HarfBuzz: MIT", name: "HarfBuzz-MIT"),
        Resource(title: "libunibreak: zlib", name: "libunibreak-Zlib"),
        Resource(title: "libplacebo: LGPL 2.1", name: "libplacebo-LGPL-2.1"),
        Resource(title: "fast_float: MIT", name: "fast_float-MIT"),
        Resource(title: "glad: CC0 / Apache 2.0", name: "glad-CC0-1.0-Apache-2.0"),
        Resource(title: "Vulkan-Headers: MIT", name: "Vulkan-Headers-MIT"),
        Resource(title: "Little CMS: MIT", name: "LittleCMS-MIT"),
        Resource(title: "libdovi: MIT", name: "libdovi-MIT"),
        Resource(title: "Rust standard library: MIT", name: "Rust-Standard-Library-MIT"),
        Resource(title: "MoltenVK: Apache 2.0", name: "MoltenVK-Apache-2.0"),
        Resource(title: "SPIRV-Cross: Apache 2.0", name: "SPIRV-Cross-Apache-2.0"),
        Resource(title: "SPIRV-Tools: Apache 2.0", name: "SPIRV-Tools-Apache-2.0"),
        Resource(title: "SPIRV-Headers: MIT", name: "SPIRV-Headers-MIT"),
        Resource(title: "cereal: BSD 3-Clause", name: "cereal-BSD-3-Clause"),
        Resource(title: "shaderc: Apache 2.0", name: "shaderc-Apache-2.0"),
        Resource(title: "glslang: BSD, MIT, Apache 2.0 and others", name: "glslang-Multiple"),
        Resource(title: "dav1d: BSD 2-Clause", name: "dav1d-BSD-2-Clause"),
        Resource(title: "uavs3d: BSD 3-Clause", name: "uavs3d-BSD-3-Clause"),
        Resource(title: "OpenSSL: Apache 2.0", name: "OpenSSL-Apache-2.0"),
        Resource(title: "libbluray: LGPL 2.1", name: "libbluray-LGPL-2.1"),
        Resource(title: "libudfread: LGPL 2.1", name: "libudfread-LGPL-2.1"),
        Resource(title: "uchardet: MPL 1.1, GPL 2.0 or LGPL 2.1", name: "uchardet-MPL-1.1"),
        Resource(title: "CollectionHStack: MIT", name: "CollectionHStack-MIT"),
        Resource(title: "DifferenceKit: Apache 2.0", name: "DifferenceKit-Apache-2.0"),
        Resource(title: "ThumbHash decoder: MIT", name: "ThumbHash-MIT"),
    ]

    static let sourceTitle = "Source for this build"

    static let text: String = (["\(sourceTitle)\n\(String(repeating: "=", count: sourceTitle.count))\n\n\(VividAbout.sourceNotice)"] + resources.map { resource in
        let body: String
        if let url = resourceURL(named: resource.name),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            body = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = "The bundled license resource \(resource.name).txt is unavailable."
        }

        return "\(resource.title)\n\(String(repeating: "=", count: resource.title.count))\n\n\(body)"
    })
    .joined(separator: "\n\n\n")

    struct Block: Identifiable, Sendable {
        let id: Int
        let title: String
        let text: String
    }

    // Cached once, and first accessed from a utility task by the TV page.
    static let blocks: [Block] = {
        var result = [Block(id: 0, title: sourceTitle, text: VividAbout.sourceNotice)]
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
struct TVOpenSourceAcknowledgementsPage: View {
    @Environment(\.dismiss) private var dismiss
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
        .onExitCommand { dismiss() }
        .task {
            let loaded = await Task.detached(priority: .utility) { OpenSourceAcknowledgements.blocks }.value
            guard !Task.isCancelled else { return }
            blocks = loaded
        }
    }
}
#endif
