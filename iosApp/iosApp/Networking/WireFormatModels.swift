import Foundation

// Silo payloads decoded with HTTPClient's shared snake_case coders, so every
// property name here is the wire name in camelCase.

// MARK: - Profiles

/// The full profile the server sends. `VividAPI` turns it into the smaller
/// ``UserProfile`` the UI uses.
struct Profile: Codable {
    let id: String
    let name: String
    let avatar: String?
    /// The server-resolved picture. For uploads this is a short-lived signed
    /// URL that changes on every fetch, so never keep it long term. Other
    /// pictures may be absolute URLs or server-relative paths.
    let avatarUrl: String?
    /// "upload", "preset" or "none".
    let avatarSource: String?
    let hasPin: Bool?
    let isChild: Bool?
    let isPrimary: Bool?
    let maxContentRating: String?
    let qualityPreference: String?
    let language: String?
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
    /// ISO 639-1 metadata language. Empty or nil uses the library default.
    /// The server translates overviews and taglines with it.
    let preferredMetadataLanguage: String?
    let autoSkipIntro: Bool?
    let autoSkipCredits: Bool?
    let autoSkipRecap: Bool?
    let libraryRestrictionsEnabled: Bool?
    let allowedLibraryIds: [Int]?
    let maxPlaybackQuality: String?
    let createdAt: String?
    let updatedAt: String?

    var asUserProfile: UserProfile {
        UserProfile(
            id: id,
            name: name,
            avatarEmoji: avatar,
            avatarImageUrl: avatarUrl,
            hasPin: hasPin ?? false,
            isChild: isChild ?? false,
            isPrimary: isPrimary ?? false,
            subtitleLanguage: subtitleLanguage,
            subtitleMode: subtitleMode,
            showForcedSubtitles: showForcedSubtitles,
            preferredMetadataLanguage: preferredMetadataLanguage
        )
    }
}

struct ProfilesResponse: Codable {
    let profiles: [Profile]
}

struct VerifyPinRequest: Codable {
    let pin: String
}

struct VerifyPinResponse: Codable {
    let valid: Bool
    let profileToken: String?
    let expiresAt: String?
}

/// The body of `POST /api/v1/profiles`. `VividAPI.createProfile` fills it
/// from the UI's ``CreateProfileBody``.
struct CreateProfileRequestBody: Codable {
    let name: String
    let avatar: String?
    let pin: String?
    let isChild: Bool?
    let maxContentRating: String?
    let libraryRestrictionsEnabled: Bool
    let allowedLibraryIds: [Int]
}

// MARK: - Discover

struct DiscoverResponse: Codable {
    let rows: [DiscoverRow]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([DiscoverRow].self, forKey: .rows) ?? []
    }
}

struct DiscoverRow: Codable {
    let type: String
    let label: String
    let items: [SectionItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
        items = try container.decodeIfPresent([SectionItem].self, forKey: .items) ?? []
    }
}

// MARK: - Library collections

/// One ordered section of a library's collections: a named group or the
/// anonymous ungrouped bucket.
struct LibraryCollectionSection: Identifiable, Hashable {
    /// The group id, or `"__ungrouped__"` for the anonymous bucket.
    let id: String
    /// Empty for the ungrouped bucket.
    let name: String
    /// `.regular` for the ungrouped bucket.
    let kind: LibraryCollectionKind
    let collections: [LibraryCollection]
}

/// Decodes `/api/v1/library/{id}/collections`, which comes in three shapes:
/// a bare array of collections, `{"collections": [...]}` when the server has
/// no groups, or `{"groups": [...], "ungrouped": {...}}`. A malformed element
/// is skipped instead of failing the whole response.
struct LibraryCollectionsWireResponse: Decodable {
    /// Every collection, for callers that don't care about grouping.
    let collections: [LibraryCollection]
    /// Groups and the ungrouped bucket in `sort_order`. Empty for flat shapes.
    let sections: [LibraryCollectionSection]

    private enum CodingKeys: String, CodingKey {
        case collections
        case groups
        case ungrouped
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            collections = decodeTolerantElements(LibraryCollection.self, from: &array)
            sections = []
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let groups = decodeTolerantArray(LibraryTabGroupWire.self, from: container, forKey: .groups)
        let ungrouped = try? container.decodeIfPresent(LibraryTabUngroupedWire.self, forKey: .ungrouped)

        guard !groups.isEmpty || ungrouped != nil else {
            collections = decodeTolerantArray(LibraryCollection.self, from: container, forKey: .collections)
            sections = []
            return
        }

        var flat: [LibraryCollection] = []
        var slots: [(order: Int, section: LibraryCollectionSection)] = []
        for group in groups {
            let items = group.collections.map { $0.toModel(kind: group.kind) }
            flat.append(contentsOf: items)
            slots.append((
                order: group.sortOrder,
                section: LibraryCollectionSection(id: group.id, name: group.name, kind: group.kind, collections: items)
            ))
        }
        if let ungrouped, !ungrouped.collections.isEmpty {
            let items = ungrouped.collections.map { $0.toModel(kind: .regular) }
            slots.append((
                order: ungrouped.sortOrder ?? .max,
                section: LibraryCollectionSection(id: "__ungrouped__", name: "", kind: .regular, collections: items)
            ))
        }
        collections = flat
        sections = slots.sorted { $0.order < $1.order }.map { $0.section }
    }
}

/// One element of `groups`.
private struct LibraryTabGroupWire: Decodable {
    let id: String
    let name: String
    let kind: LibraryCollectionKind
    let sortOrder: Int
    let collections: [LibraryTabCollectionWire]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case sortOrder
        case collections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "Group", comment: "Fallback name for a library collection group the server sent without one")
        // An unknown or missing kind is regular rather than a failed group.
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(LibraryCollectionKind.init(rawValue:)) ?? .regular
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        collections = decodeTolerantArray(LibraryTabCollectionWire.self, from: container, forKey: .collections)
    }
}

/// The `ungrouped` bucket.
private struct LibraryTabUngroupedWire: Decodable {
    let sortOrder: Int?
    let collections: [LibraryTabCollectionWire]

    enum CodingKeys: String, CodingKey {
        case sortOrder
        case collections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        collections = decodeTolerantArray(LibraryTabCollectionWire.self, from: container, forKey: .collections)
    }
}

/// A collection inside a group or the ungrouped bucket: a subset of a
/// library collection's fields.
private struct LibraryTabCollectionWire: Decodable {
    let id: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let itemCount: Int?
    let creatorProfileId: String?

    func toModel(kind: LibraryCollectionKind) -> LibraryCollection {
        LibraryCollection(
            id: id,
            name: title,
            collectionType: nil,
            itemCount: itemCount,
            posterUrl: posterUrl,
            posterThumbhash: posterThumbhash,
            kind: kind,
            creatorProfileId: creatorProfileId
        )
    }
}

/// Decodes anything without failing, so a malformed element can be stepped
/// over in an unkeyed container.
private struct SkippedElement: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Decodes each remaining element, skipping the ones that fail. Stops if the
/// cursor ever fails to move, so a bad element can't loop forever.
private func decodeTolerantElements<T: Decodable>(
    _ type: T.Type,
    from container: inout UnkeyedDecodingContainer
) -> [T] {
    var elements: [T] = []
    while !container.isAtEnd {
        let before = container.currentIndex
        if let element = try? container.decode(T.self) {
            elements.append(element)
        } else {
            _ = try? container.decode(SkippedElement.self)
        }
        if container.currentIndex == before { break }
    }
    return elements
}

/// Decodes an array field, skipping elements that fail. A missing or
/// non-array field is empty.
private func decodeTolerantArray<T: Decodable, K: CodingKey>(
    _ type: T.Type,
    from container: KeyedDecodingContainer<K>,
    forKey key: K
) -> [T] {
    guard var array = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
    return decodeTolerantElements(T.self, from: &array)
}
