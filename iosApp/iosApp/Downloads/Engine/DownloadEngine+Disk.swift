import Foundation

/// Where downloads live: `<Application Support>/VividDownloads`.
enum DownloadFilePaths {
    /// The downloads root, made when missing and kept out of backups. Every
    /// download file lives under it.
    static func rootDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("VividDownloads", isDirectory: true)
        DownloadEngine.Disk.makeFolder(root, excludedFromBackup: true)
        return root
    }
}

extension DownloadEngine {
    /// Folder layout: `<root>/<server>/<profile>/<download id>/`, plus
    /// `<root>/staging/` for finished transfers waiting to be moved.
    enum Disk {
        static let storeFileName = "store.json"
        static let manifestFileName = "manifest.json"
        static let posterFileName = "poster.jpg"
        static let backdropFileName = "backdrop.jpg"
        static let logoFileName = "logo.png"
        static let resumeFileName = "resume.bin"

        /// Makes a folder when it's missing. A folder that can't be made is
        /// logged; the write that follows then fails on its own.
        static func makeFolder(_ url: URL, excludedFromBackup: Bool = false) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                log.error("Couldn't create a downloads folder: \(error.localizedDescription, privacy: .private)")
            }
            guard excludedFromBackup else { return }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = url
            try? marked.setResourceValues(values)
        }

        static func stagingDirectory() -> URL {
            let staging = DownloadFilePaths.rootDirectory().appendingPathComponent("staging", isDirectory: true)
            makeFolder(staging, excludedFromBackup: true)
            return staging
        }

        static func stagedFile(taskIdentifier: Int) -> URL {
            stagingDirectory().appendingPathComponent("task-\(taskIdentifier).bin", isDirectory: false)
        }

        static func scopeDirectory(_ scope: DownloadScope) -> URL {
            let folder = DownloadFilePaths.rootDirectory()
                .appendingPathComponent(folderName(scope.serverId), isDirectory: true)
                .appendingPathComponent(folderName(scope.profileId), isDirectory: true)
            makeFolder(folder)
            return folder
        }

        static func storeFile(_ scope: DownloadScope) -> URL {
            scopeDirectory(scope).appendingPathComponent(storeFileName, isDirectory: false)
        }

        static func downloadDirectory(_ scope: DownloadScope, downloadId: String) -> URL {
            let folder = scopeDirectory(scope).appendingPathComponent(folderName(downloadId), isDirectory: true)
            makeFolder(folder)
            return folder
        }

        static func file(_ name: String, scope: DownloadScope, downloadId: String) -> URL {
            downloadDirectory(scope, downloadId: downloadId).appendingPathComponent(name, isDirectory: false)
        }

        /// An id as a folder name, one Unicode scalar at a time: letters and
        /// numbers of any script and `-`, `_`, `.` stay, anything else becomes
        /// `_`. Existing folders depend on this, so it never changes.
        static func folderName(_ raw: String) -> String {
            var scalars = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                let character = Character(scalar)
                let kept = character.isLetter || character.isNumber || scalar == "-" || scalar == "_" || scalar == "."
                scalars.append(kept ? scalar : "_")
            }
            let name = String(scalars)
            return name.isEmpty || name.allSatisfy({ $0 == "." }) ? "_" : name
        }

        /// `media.<ext>` from the container's name.
        static func mediaFileName(container: String?) -> String {
            let ext: String
            switch container?.lowercased() {
            case "mkv", "matroska": ext = "mkv"
            case let known? where ["mov", "m4v", "webm", "avi", "ts", "m2ts"].contains(known): ext = known
            default: ext = "mp4"
            }
            return "media.\(ext)"
        }

        static func fileSize(at url: URL) -> Int64 {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size ?? 0
        }

        /// Every regular file under a folder, recursively.
        static func bytesUnder(_ folder: URL) -> Int64 {
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            ) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }

        /// Replaces whatever is at `destination` with the file at `source`.
        static func move(_ source: URL, to destination: URL) throws {
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: source, to: destination)
        }

        static func remove(_ url: URL) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reads and writes scope files and manifests off the main actor.
    actor Store {
        static let shared = Store()

        private let decoder = JSONDecoder()
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return encoder
        }()

        /// The scope's saved state, or the empty state when it has none or it
        /// can't be read.
        func load(_ scope: DownloadScope) -> DownloadStoreFile {
            guard !scope.serverId.isEmpty, !scope.profileId.isEmpty else { return .empty }
            guard let data = try? Data(contentsOf: Disk.storeFile(scope)) else { return .empty }
            do {
                var state = try decoder.decode(DownloadStoreFile.self, from: data)
                state.version = 1
                return state
            } catch {
                log.error("Couldn't read the downloads store: \(error.localizedDescription, privacy: .public)")
                return .empty
            }
        }

        /// Writes the scope's state, logging a failure.
        func save(_ state: DownloadStoreFile, to scope: DownloadScope) {
            do {
                try write(state, to: scope)
            } catch {
                log.error("Couldn't save the downloads store: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// The same write, throwing its failure.
        func write(_ state: DownloadStoreFile, to scope: DownloadScope) throws {
            guard !scope.serverId.isEmpty, !scope.profileId.isEmpty else { throw HTTPError.requestIdentityChanged }
            let data = try encoder.encode(state)
            try data.write(to: Disk.storeFile(scope), options: .atomic)
        }

        func writeManifest(_ manifest: OfflineManifest, to url: URL) {
            guard let data = try? encoder.encode(manifest) else { return }
            try? data.write(to: url, options: .atomic)
        }

        func readManifest(at url: URL) -> OfflineManifest? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(OfflineManifest.self, from: data)
        }
    }
}
