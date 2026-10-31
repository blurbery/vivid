import Foundation

/// The server's artwork size capability. Callers decode it with
/// `.convertFromSnakeCase`.
struct ImageSizeCapabilityResponse: Codable, Equatable {
    let schemaVersion: Int
    let param: String
    let sizes: [String]
    let widths: [String: [String: Int]]
    let originalMaxWidthPx: Int
}

enum ImageSizeSelection {
    static let preferredSize = "large"

    /// The query item that asks for large artwork, or nothing when the server
    /// can't serve it or large images aren't wanted.
    static func queryEntries(capability: ImageSizeCapabilityResponse?, prefersLargeImages: Bool) -> [String: String] {
        guard prefersLargeImages,
              let capability,
              capability.schemaVersion == 1,
              !capability.param.isEmpty,
              capability.sizes.contains(preferredSize)
        else { return [:] }
        return [capability.param: preferredSize]
    }
}
