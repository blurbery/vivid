import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Transfer rate

    /// Exponentially-smoothed rate from progress deltas. Samples at least
    /// `rateSampleInterval` apart so the burst-y delegate callbacks don't
    /// produce jittery instantaneous rates.
    func updateTransferRate(recordId: String, bytes: Int64) {
        let now = Date()
        guard let sample = rateSamples[recordId] else {
            rateSamples[recordId] = (bytes, now)
            return
        }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= Self.rateSampleInterval else { return }
        // Resume-data restarts can report fewer bytes than the last sample;
        // reset the window instead of publishing a negative rate.
        guard bytes >= sample.bytes else {
            rateSamples[recordId] = (bytes, now)
            transferRates.removeValue(forKey: recordId)
            return
        }
        let instant = Double(bytes - sample.bytes) / elapsed
        if let previous = transferRates[recordId] {
            transferRates[recordId] = previous + Self.rateSmoothing * (instant - previous)
        } else {
            transferRates[recordId] = instant
        }
        rateSamples[recordId] = (bytes, now)
    }

    func clearTransferRate(recordId: String) {
        rateSamples.removeValue(forKey: recordId)
        transferRates.removeValue(forKey: recordId)
        lastProgressPublish.removeValue(forKey: recordId)
    }
}
