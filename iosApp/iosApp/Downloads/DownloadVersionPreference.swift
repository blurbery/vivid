import Foundation

/// An original-file version chosen for season, series and multi-episode
/// downloads, or as the default in Settings. Every episode is a different
/// file, so the choice is a rule matched per episode: its resolution class
/// and, where set, HDR.
struct DownloadVersionPreference: Hashable, Sendable {
    /// Resolution class: 2160, 1080, 720, or 480 for anything smaller.
    let height: Int
    /// nil matches HDR and SDR alike.
    let hdr: Bool?

    init(height: Int, hdr: Bool?) {
        self.height = height
        self.hdr = hdr
    }

    static let classes = [2160, 1080, 720, 480]

    /// "4K HDR", "1080p", "SD".
    var label: String {
        let base: String
        switch height {
        case 2160: base = "4K"
        case 480: base = "SD"
        default: base = "\(height)p"
        }
        return hdr == true ? "\(base) HDR" : base
    }

    // MARK: - Menu tags

    /// Quality menus select one string: a quality preset ("original",
    /// "10mbps") or a version of the original file, tagged "original@1080",
    /// "original@2160-hdr" or "original@2160-sdr".
    static let tagPrefix = "original@"

    var tag: String {
        let range = hdr == true ? "-hdr" : hdr == false ? "-sdr" : ""
        return "\(Self.tagPrefix)\(height)\(range)"
    }

    init?(tag: String) {
        guard tag.hasPrefix(Self.tagPrefix) else { return nil }
        let parts = tag.dropFirst(Self.tagPrefix.count).split(separator: "-", maxSplits: 1)
        guard let first = parts.first, let height = Int(first), Self.classes.contains(height) else { return nil }
        switch parts.count > 1 ? String(parts[1]) : nil {
        case nil: self.init(height: height, hdr: nil)
        case "hdr": self.init(height: height, hdr: true)
        case "sdr": self.init(height: height, hdr: false)
        default: return nil
        }
    }

    /// The server quality and version a menu tag stands for.
    static func split(_ tag: String) -> (quality: String, version: DownloadVersionPreference?) {
        if let version = DownloadVersionPreference(tag: tag) {
            return (DownloadFormat.original.rawValue, version)
        }
        return (tag, nil)
    }

    // MARK: - Matching

    /// A file's resolution class, or nil when its resolution is unknown.
    /// Accepts "1080p", "4K" and "1920x1080" (Emby and Jellyfin report
    /// files under 720p by their height, such as "576p").
    static func heightClass(of resolution: String?) -> Int? {
        guard let raw = resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if raw == "4k" || raw == "uhd" { return 2160 }
        let numbers = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let height = numbers.last, height > 0 else { return nil }
        switch height {
        case 2000...: return 2160
        case 1000..<2000: return 1080
        case 700..<1000: return 720
        default: return 480
        }
    }

    /// The versions these files offer, highest first: one per resolution
    /// class, split into HDR and SDR only where a class has both.
    static func options(for files: [EpisodeFile]) -> [DownloadVersionPreference] {
        var ranges: [Int: Set<Bool>] = [:]
        for file in files {
            guard let height = heightClass(of: file.resolution) else { continue }
            ranges[height, default: []].insert(file.hdr == true)
        }
        return classes.flatMap { height -> [DownloadVersionPreference] in
            guard let found = ranges[height] else { return [] }
            if found.count > 1 {
                return [DownloadVersionPreference(height: height, hdr: true), DownloadVersionPreference(height: height, hdr: false)]
            }
            return [DownloadVersionPreference(height: height, hdr: found.contains(true) ? true : nil)]
        }
    }

    /// The file this version picks from one item's files: the same class
    /// and HDR, then the same class either way. nil leaves the choice to
    /// the server.
    func match<File>(_ files: [File], resolution: (File) -> String?, hdr: (File) -> Bool?) -> File? {
        let sameClass = files.filter { Self.heightClass(of: resolution($0)) == height }
        if let wanted = self.hdr, let exact = sameClass.first(where: { (hdr($0) == true) == wanted }) {
            return exact
        }
        return sameClass.first
    }

    func file(in files: [EpisodeFile]) -> EpisodeFile? {
        match(files, resolution: \.resolution, hdr: \.hdr)
    }

    func version(in versions: [FileVersion]) -> FileVersion? {
        match(versions, resolution: \.resolution, hdr: \.hdr)
    }

    /// The menu option a default (such as Settings' "Original · 1080p")
    /// lands on: the same class, preferring the matching HDR range.
    func option(in options: [DownloadVersionPreference]) -> DownloadVersionPreference? {
        let sameClass = options.filter { $0.height == height }
        if let hdr, let exact = sameClass.first(where: { ($0.hdr == true) == hdr }) { return exact }
        return sameClass.first { $0.hdr != true } ?? sameClass.first
    }
}
