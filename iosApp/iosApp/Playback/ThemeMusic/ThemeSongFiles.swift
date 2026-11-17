import Foundation

/// Downloaded theme songs, kept in temporaryDirectory/ThemeMusic. Playing a
/// local file needs no request headers in `AVPlayer` and gives it a known
/// duration, even for a server's mp3 conversion.
enum ThemeSongFiles {
    static let maximumBytes = 32 * 1024 * 1024
    /// The newest files kept, so a song still fading out isn't deleted
    /// under the player when the next one arrives.
    static let keptFiles = 3

    static var defaultFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ThemeMusic", isDirectory: true)
    }

    private static let lock = NSLock()

    /// Writes the song and returns its file URL, keeping only the newest few
    /// files (older ones are deleted, never the one just written). nil on any
    /// failure, or if the data is empty or larger than `maximumBytes`.
    static func store(_ data: Data, fileExtension: String, in folder: URL = defaultFolder) -> URL? {
        let fileExtension = fileExtension.lowercased()
        guard !data.isEmpty, data.count <= maximumBytes, !fileExtension.isEmpty,
              fileExtension.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            removeOlderFiles(in: folder, keeping: url)
            return url
        } catch {
            return nil
        }
    }

    private static func removeOlderFiles(in folder: URL, keeping newest: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let others = files
            .filter { $0.lastPathComponent != newest.lastPathComponent }
            .sorted { modified($0) > modified($1) }
        for old in others.dropFirst(max(keptFiles - 1, 0)) {
            try? manager.removeItem(at: old)
        }
    }

    /// The extension `AVPlayer` needs to open a downloaded song, which it
    /// reads from the file name: from the reply's `Content-Type`, else the
    /// file's first bytes. nil when neither names a format it plays.
    static func fileExtension(contentType: String?, data: Data) -> String? {
        if let contentType,
           let type = contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           let known = contentTypes[type] {
            return known
        }
        return sniffedExtension(data)
    }

    private static let contentTypes: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mpeg3": "mp3", "audio/x-mpeg": "mp3",
        "audio/mp4": "m4a", "audio/m4a": "m4a", "audio/x-m4a": "m4a", "audio/x-m4b": "m4b",
        "video/mp4": "mp4", "video/quicktime": "mov",
        "audio/aac": "aac", "audio/aacp": "aac", "audio/x-aac": "aac",
        "audio/flac": "flac", "audio/x-flac": "flac",
        "audio/wav": "wav", "audio/wave": "wav", "audio/x-wav": "wav", "audio/vnd.wave": "wav",
        "audio/aiff": "aiff", "audio/x-aiff": "aiff",
        "audio/x-caf": "caf",
    ]

    /// The format from the file's own signature, for servers that send a
    /// generic `Content-Type` such as `application/octet-stream`.
    private static func sniffedExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func ascii(_ range: Range<Int>) -> String? {
            range.upperBound <= bytes.count ? String(bytes: bytes[range], encoding: .ascii) : nil
        }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(0..<4) == "caff" { return "caf" }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
        if ascii(0..<4) == "FORM", ["AIFF", "AIFC"].contains(ascii(8..<12)) { return "aiff" }
        if ascii(4..<8) == "ftyp" { return "m4a" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            // An MPEG frame sync: layer bits of zero mean ADTS AAC, others MP3.
            return bytes[1] & 0x06 == 0 ? "aac" : "mp3"
        }
        return nil
    }
}
