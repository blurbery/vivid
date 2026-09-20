import Foundation

enum MediaServerProvider: String, Codable, Sendable {
    case silo, emby, jellyfin
    var name: String { switch self { case .silo: "Silo"; case .emby: "Emby"; case .jellyfin: "Jellyfin" } }
    var usesNativeUser: Bool { self == .emby || self == .jellyfin }
    var serverPlaceholder: String { rawValue + ".example.com" }
    static func forServerID(_ id: String?) -> Self { id?.hasPrefix("jellyfin:") == true ? .jellyfin : id?.hasPrefix("emby:") == true ? .emby : .silo }
    static var active: Self { forServerID(ServerRegistry.activeServerIDSnapshot) }
}
