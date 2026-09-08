#if os(tvOS)
import SwiftUI

struct TVHomeScreenSettingsView: View {
    @State private var preferences = TVHomeSpotlightPreferences.shared
    @State private var sections: [ResolvedSection] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @FocusState private var doneFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var selected: [String] { preferences.selectedRowIDs ?? [] }
    private var missingRowIDs: [String] {
        selected.filter { id in !sections.contains { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Home Screen Discovery Spotlight")
                            .font(.system(size: 38, weight: .bold))
                        Spacer()
                        Button { dismiss() } label: {
                            Text("Done").frame(maxWidth: .infinity, alignment: .center)
                        }
                            .buttonStyle(TVSettingsPaneRowStyle())
                            .frame(width: 150)
                            .focused($doneFocused)
                    }
                    TVSettingsFooter("Choose up to 3 Home rows to supply the spotlight. It shows up to 10 slides and changes every 6 seconds. These choices are separate from Home Sections.")
                    TVSettingsSectionHeader("\(selected.count) OF 3 ROWS SELECTED")

                    if isLoading && sections.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if loadFailed && sections.isEmpty {
                        TVSettingsFooter("Couldn’t load your Home rows.")
                        Button("Try Again") { Task { await loadSections() } }
                    } else {
                        TVSettingsGroup {
                            ForEach(sections) { section in
                                row(id: section.id, title: section.title)
                            }
                            ForEach(missingRowIDs, id: \.self) { id in
                                row(id: id, title: "Unavailable Home row — remove from spotlight")
                            }

                        }
                        if sections.isEmpty {
                            TVSettingsFooter("Your Home rows will appear here when your server has media to show.")
                        } else {
                            TVSettingsFooter(selected.count == 3
                                ? "To choose a different row, turn off one of the selected rows first."
                                : "Choose no rows to hide the spotlight. Changes save automatically.")
                        }
                    }
                }
                .frame(maxWidth: 1360, alignment: .leading)
                .padding(.horizontal, 88)
                .padding(.vertical, 64)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Home Screen")
            .task { await loadSections() }
        }
        .defaultFocus($doneFocused, true)
        .onExitCommand { dismiss() }
    }

    private func row(id: String, title: String) -> some View {
        let isSelected = selected.contains(id)
        return Button { preferences.toggle(id) } label: {
            HStack(spacing: 18) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                TVSettingsRowLabel(title: title, detail: isSelected ? "Used in the discovery spotlight." : "Choose this row as a spotlight source.")
                Spacer()
            }
            .font(.system(size: 26))
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(!isSelected && selected.count == 3
            ? "Three rows are selected. Turn one off to select this row."
            : "Toggle spotlight source")
    }

    private func loadSections() async {
        preferences.refresh()
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            sections = cached.sections.filter { !$0.items.isEmpty }
            preferences.initializeIfNeeded(from: sections)
        }
        isLoading = sections.isEmpty
        loadFailed = false
        defer { isLoading = false }
        do {
            let response = try await StartupContentPrefetcher.fetchHomeSections()
            guard !Task.isCancelled else { return }
            sections = response.sections.filter { !$0.items.isEmpty }
            preferences.initializeIfNeeded(from: sections)
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
#endif
