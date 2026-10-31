import Foundation
import OSLog

/// Home for the downloads core's shared helpers: storage, the transfer
/// session, progress rules, grouping and the offline pieces. Only the core
/// declares it, so its nested names never clash with the downloads screens.
enum DownloadEngine {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app", category: "Downloads")

    /// The text joining parts of a status line, title or label.
    static let dot = " · "
}
