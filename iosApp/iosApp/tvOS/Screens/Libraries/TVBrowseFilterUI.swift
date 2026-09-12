#if os(tvOS)
import SwiftUI

/// Native menus own presentation, dismissal, and focus restoration.
struct TVBrowseControlRow: View {
    let mediaType: BrowseMediaType
    let filter: CatalogFilterState
    let facets: CatalogFacets?
    let isLoadingFacets: Bool
    let facetsLoadFailed: Bool
    var facetsFailureReason: String? = nil
    let showsAlphabetMenu: Bool
    let preserveEnabled: Bool
    var focusRequest: Int = 0
    var returnControl: TVBrowseControlFocus = .sort
    var onFocus: ((TVBrowseControlFocus) -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    let onSort: (CatalogSortKey) -> Void
    let onFilterChange: (CatalogFilterState) -> Void
    let onPreserveChange: (Bool) -> Void
    let onLoadFacets: () -> Void
    let onSelectPrefix: (String?) -> Void

    @FocusState private var focusedControl: TVBrowseControlFocus?
    @State private var lastAppliedFocusRequest = 0
    @State private var preserve = false

    var body: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(CatalogSortKey.available(for: mediaType), id: \.self) { key in
                    Button { onSort(key) } label: {
                        if key == filter.sort {
                            Label("\(key.label) · \(key.directionLabel(for: filter.effectiveOrder))", systemImage: "checkmark")
                        } else { Text(key.label) }
                    }
                }
            } label: {
                Label("Sort · \(filter.sort.label) \(filter.sort.directionLabel(for: filter.effectiveOrder))", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(TVBrowseControlPillStyle())
            .focused($focusedControl, equals: .sort)

            if facetsLoadFailed {
                Button(facetsFailureReason.map { "Retry filters · " + $0 } ?? "Retry filters", action: onLoadFacets)
                    .buttonStyle(TVBrowseControlPillStyle())
                    .focused($focusedControl, equals: .filter)
            } else {
            Menu {
                if let facets {
                    ForEach(CatalogFacet.available(for: mediaType), id: \.self) { facet in
                        let options = facets.optionPairs(for: facet, hasProfile: AuthService.shared.hasProfile)
                        if !options.isEmpty {
                            Menu(facet.title) {
                                ForEach(options, id: \.value) { option in
                                    Toggle(option.label, isOn: Binding(
                                        get: { filter.isSelected(facet, value: option.value) },
                                        set: { selected in
                                            guard selected != filter.isSelected(facet, value: option.value) else { return }
                                            var next = filter
                                            next.toggle(facet, value: option.value)
                                            onFilterChange(next)
                                        }
                                    ))
                                    .menuActionDismissBehavior(.disabled)
                                }
                                Button("Clear \(facet.title)") {
                                    var next = filter; next.clear(facet); onFilterChange(next)
                                }
                                .disabled(filter.selectedValues(facet).isEmpty)
                            }
                        }
                    }
                } else {
                    Button(isLoadingFacets ? "Loading filters…" : "Reload filter options", action: onLoadFacets)
                        .disabled(isLoadingFacets)
                }
                if MediaServerProvider.active != .emby {
                Section("Match") {
                    Toggle("Match all selected filters", isOn: Binding(
                        get: { filter.matchAll },
                        set: { value in var next = filter; next.matchAll = value; onFilterChange(next) }
                    ))
                    .menuActionDismissBehavior(.disabled)
                }
                }
                Section {
                    Toggle("Preserve sort & filters", isOn: Binding(
                        get: { preserve },
                        set: { preserve = $0; onPreserveChange($0) }
                    ))
                    .menuActionDismissBehavior(.disabled)
                    Button("Reset filters") {
                        var next = filter; next.resetFilters(); onFilterChange(next)
                    }
                    .disabled(!filter.canResetFilters)
                }
            } label: {
                Label(filter.activeFacetCount > 0 ? "Filter · \(filter.activeFacetCount)" : "Filter", systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.button)
            .buttonStyle(TVBrowseControlPillStyle(active: filter.activeFacetCount > 0))
            .focused($focusedControl, equals: .filter)
            .disabled(facets == nil)
            .accessibilityHint(facets == nil ? "Filter options are loading" : "Choose filters")
            }
            Spacer(minLength: 0)
            if showsAlphabetMenu {
                TVAlphabetMenu(selected: filter.namePrefix, onSelect: onSelectPrefix)
                    .focused($focusedControl, equals: .alphabet)
            }
        }
        .font(.system(size: 24, weight: .medium))
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .up:
                if let onMoveUp { focusedControl = nil; onMoveUp() }
            case .down:
                if let onMoveDown { focusedControl = nil; onMoveDown() }
            default: break
            }
        }
        .onAppear {
            preserve = preserveEnabled
            applyFocusRequest()
        }
        .onChange(of: focusRequest) { _, _ in applyFocusRequest() }
        .onChange(of: focusedControl) { _, control in
            if let control { onFocus?(control) }
        }
    }

    private func applyFocusRequest() {
        guard focusRequest > 0, focusRequest != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = focusRequest
        focusedControl = returnControl
    }
}

enum TVBrowseControlFocus: Hashable {
    case sort
    case filter
    case alphabet
}

struct TVBrowseControlPillStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        TVBrowseControlPillBody(configuration: configuration, active: active)
    }
}

private struct TVBrowseControlPillBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .foregroundColor(isFocused ? .vividBackground : .vividOnSurface)
            .background(
                Capsule().fill(
                    isFocused ? Color.vividOnSurface
                        : (active ? Color.vividChromeSelectedFill : Color.vividChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.clear : Color.vividChromeRestingBorder,
                    lineWidth: 1
                )
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

#endif
