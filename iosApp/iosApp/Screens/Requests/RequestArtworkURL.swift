import Foundation

/// Image URLs for the raw TMDb artwork paths Seerr returns.
enum RequestArtworkURL {
    static func poster(_ path: String?) -> String? {
        url(for: path, size: "w342")
    }

    static func backdrop(_ path: String?) -> String? {
        url(for: path, size: "w1280")
    }

    private static func url(for path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        guard path.hasPrefix("/") else { return nil }
        return "https://image.tmdb.org/t/p/" + size + path
    }
}
