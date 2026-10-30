import Foundation

/// Whether a library belongs under the Movies or Series tab. Mixed libraries
/// belong under both.
func libraryMatchesPrimaryMenuCategory(_ library: Library, category: PrimaryMenuBuiltin) -> Bool {
    switch category {
    case .movies: library.isMixedLibrary || library.isMovieLibrary
    case .series: library.isMixedLibrary || library.isSeriesLibrary
    case .home, .forYou: false
    }
}

/// The libraries a library root can show. A root fixed to one library also
/// shows the libraries that share its kind.
func visibleLibrariesForRoot(_ libraries: [Library], category: PrimaryMenuBuiltin?, fixedLibraryId: Int?) -> [Library] {
    if let fixedLibraryId {
        guard let fixed = libraries.first(where: { $0.id == fixedLibraryId }) else { return [] }
        return libraries.filter { library in
            if library.id == fixedLibraryId { return true }
            if fixed.isMixedLibrary { return library.isMixedLibrary }
            return [PrimaryMenuBuiltin.movies, .series].contains { category in
                libraryMatchesPrimaryMenuCategory(library, category: category)
                    && libraryMatchesPrimaryMenuCategory(fixed, category: category)
            }
        }
    }
    guard let category else { return libraries }
    return libraries.filter { libraryMatchesPrimaryMenuCategory($0, category: category) }
}

/// The app never fixes a library root to one library today. This helper and
/// the fixed-library rules in the others stay because they're part of the root
/// contract `InterfacePreferencesTests` checks.
func libraryRootCanSwitch(fixedLibraryId: Int?, visibleLibraryCount: Int) -> Bool {
    visibleLibraryCount > 1
}

/// The library a root opens on: a fixed root keeps the current choice or
/// falls back to its own library; otherwise the stored choice, else the first.
func resolvedLibraryIdForRoot(
    _ libraries: [Library],
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    storedLibraryId: Int,
    currentSelectionId: Int? = nil
) -> Int? {
    let visibleIds = visibleLibrariesForRoot(libraries, category: category, fixedLibraryId: fixedLibraryId).map(\.id)
    if let fixedLibraryId {
        if let currentSelectionId, visibleIds.contains(currentSelectionId) { return currentSelectionId }
        return visibleIds.contains(fixedLibraryId) ? fixedLibraryId : nil
    }
    if storedLibraryId != 0, visibleIds.contains(storedLibraryId) { return storedLibraryId }
    return visibleIds.first
}

private let librarySelectionBaseKey = "librariesTabSelectedLibraryId"

/// Where a root's library choice is kept: one key for the Libraries tab, and
/// one per server, profile and category for the Movies and Series tabs.
func librarySelectionStorageKey(
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    authority: MainTabLibraryAuthority?
) -> String? {
    guard fixedLibraryId == nil else { return nil }
    guard let category else { return librarySelectionBaseKey }
    guard let authority else { return nil }
    return "\(librarySelectionBaseKey).\(authority.serverId):\(authority.profileId):category:\(category.rawValue)"
}

/// The stored choice for `storageKey`, falling back to the Libraries tab's
/// choice, and 0 when there is none.
func storedLibrarySelectionId(for storageKey: String?, defaults: UserDefaults = .standard) -> Int {
    guard let storageKey else { return 0 }
    if defaults.object(forKey: storageKey) != nil {
        return defaults.integer(forKey: storageKey)
    }
    return defaults.integer(forKey: librarySelectionBaseKey)
}
