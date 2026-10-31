#if os(iOS)
import SwiftUI

extension DownloadScreens {
    /// Free Up Space: downloads that have been watched, all picked to delete
    /// until someone chooses to keep some.
    struct ReclaimSheet: View {
        /// Record ids to keep. Everything else, including rows that turn up
        /// later, is picked.
        @State private var kept: Set<String> = []
        @Environment(\.dismiss) private var dismiss

        private var manager: DownloadManager { .shared }

        var body: some View {
            let rows = manager.watchedToClear
            NavigationStack {
                Group {
                    if rows.isEmpty {
                        EmptyStateView(
                            icon: "checkmark.circle",
                            title: "All Caught Up",
                            subtitle: "There are no watched downloads to clear right now."
                        )
                    } else {
                        list(rows)
                    }
                }
                .background(Color.clear)
                .navigationTitle("Free Up Space")
                .navigationBarTitleDisplayMode(.inline)
                .vividToolbarColorSchemeDark()
                .toolbar {
                    VividSheetCloseItem { dismiss() }
                    if !rows.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            selectionToggle(rows)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !rows.isEmpty { bottomBar(rows) }
                }
            }
            .vividGlassSheet(startsTall: true)
        }

        private func list(_ rows: [DownloadRecord]) -> some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(rows.count) items you've finished watching")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    ForEach(rows) { record in
                        row(record)
                        Divider()
                            .overlay(Color.vividDivider)
                            .padding(.leading, 56)
                    }
                    Color.clear
                        .frame(height: 24)
                }
            }
        }

        private func row(_ record: DownloadRecord) -> some View {
            Button {
                if kept.contains(record.id) {
                    kept.remove(record.id)
                } else {
                    kept.insert(record.id)
                }
            } label: {
                HStack(spacing: 12) {
                    SelectionCircle(isSelected: !kept.contains(record.id))
                    ThumbhashImage(thumbhash: record.posterThumbhash)
                        .frame(width: 48, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Self.label(for: record))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.vividOnSurface)
                            .lineLimit(1)
                        Text("Watched")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.vividSecondaryText)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: DownloadScreens.byteText(record.fileSize))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        /// Deselect All keeps every row; Select All keeps none.
        private func selectionToggle(_ rows: [DownloadRecord]) -> some View {
            let title: LocalizedStringKey = kept.isEmpty ? "Deselect All" : "Select All"
            return Button(title) {
                kept = kept.isEmpty ? Set(rows.map(\.id)) : []
            }
        }

        private func bottomBar(_ rows: [DownloadRecord]) -> some View {
            let chosen = rows.filter { !kept.contains($0.id) }
            let bytes = chosen.reduce(Int64(0)) { $0 + $1.fileSize }
            let notNow = RoundedRectangle(cornerRadius: 13, style: .continuous)
            return VStack(spacing: 9) {
                Button {
                    manager.remove(recordIds: chosen.map(\.id))
                    dismiss()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "trash")
                        Text("Delete \(chosen.count) · Free \(DownloadScreens.byteText(bytes))")
                            .bold()
                    }
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .downloadMenuActionSurface(cornerRadius: 15, isEnabled: !chosen.isEmpty)
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty)
                Button {
                    dismiss()
                } label: {
                    Text("Not now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.vividOnSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(notNow.fill(Color.vividChromeRestingFill))
                        .overlay(notNow.stroke(Color.vividChromeRestingBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }

        /// "Severance · S1E4" for an episode, else the title. Not localised.
        private static func label(for record: DownloadRecord) -> String {
            guard record.seriesId != nil else { return record.title ?? record.contentId }
            let tag = (record.seasonNumber.map { "S\($0)" } ?? "") + (record.episodeNumber.map { "E\($0)" } ?? "")
            let seriesName = record.seriesTitle ?? record.title ?? ""
            if tag.isEmpty { return record.title ?? seriesName }
            return "\(seriesName) · \(tag)"
        }
    }
}
#endif
