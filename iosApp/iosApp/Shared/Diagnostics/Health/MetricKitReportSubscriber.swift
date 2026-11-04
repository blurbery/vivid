#if os(iOS)
import Foundation
import MetricKit

/// Receives MetricKit diagnostic payloads (crashes, hangs, CPU and disk
/// write exceptions, slow launches) and keeps redacted summaries in the
/// on-device health store. iOS only: MetricKit is unavailable on tvOS.
///
/// The system delivers payloads roughly once a day, and straight away in
/// Xcode with Debug → Simulate MetricKit Payloads on a device.
final class MetricKitReportSubscriber: NSObject, MXMetricManagerSubscriber {
    /// MetricKit holds subscribers weakly.
    private static let shared = MetricKitReportSubscriber()
    private static let queue = DispatchQueue(label: "com.blurbery.vivid.health.metrickit", qos: .utility)

    static func install() {
        MXMetricManager.shared.add(shared)
        // Payloads delivered before this launch; the store skips any it
        // already has.
        queue.async {
            shared.ingest(MXMetricManager.shared.pastDiagnosticPayloads)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.queue.async { self.ingest(payloads) }
    }

    /// A crash the crash capture already recorded for the same process is
    /// folded into that report instead of being added again.
    private func ingest(_ payloads: [MXDiagnosticPayload]) {
        for input in payloads.flatMap(Self.inputs) {
            let report = MetricKitReportSummariser.report(from: input)
            if input.kind == .crash, let pid = input.pid,
               AppHealthStore.shared.merge(metricKitCrash: report, pid: Int(pid)) {
                continue
            }
            AppHealthStore.shared.add(report)
        }
    }

    private static func inputs(from payload: MXDiagnosticPayload) -> [MetricKitDiagnosticInput] {
        var inputs: [MetricKitDiagnosticInput] = []
        for crash in payload.crashDiagnostics ?? [] {
            var input = baseInput(.crash, crash, callStackTree: crash.callStackTree, payload: payload)
            input.values["signal"] = crash.signal.map { .int($0.intValue) }
            input.values["exception_type"] = crash.exceptionType.map { .int($0.intValue) }
            input.values["exception_code"] = crash.exceptionCode.map { .int($0.intValue) }
            input.text["termination_reason"] = crash.terminationReason
            if let reason = crash.exceptionReason {
                input.text["exception_name"] = reason.exceptionName
                input.text["exception_class"] = reason.className
                input.text["exception_kind"] = reason.exceptionType
                input.text["exception_message"] = reason.composedMessage
            }
            inputs.append(input)
        }
        for hang in payload.hangDiagnostics ?? [] {
            var input = baseInput(.hang, hang, callStackTree: hang.callStackTree, payload: payload)
            input.values["duration_ms"] = .int(milliseconds(hang.hangDuration))
            inputs.append(input)
        }
        for exception in payload.cpuExceptionDiagnostics ?? [] {
            var input = baseInput(.cpuException, exception, callStackTree: exception.callStackTree, payload: payload)
            input.values["cpu_time_ms"] = .int(milliseconds(exception.totalCPUTime))
            input.values["sampled_time_ms"] = .int(milliseconds(exception.totalSampledTime))
            inputs.append(input)
        }
        for exception in payload.diskWriteExceptionDiagnostics ?? [] {
            var input = baseInput(.diskWriteException, exception, callStackTree: exception.callStackTree, payload: payload)
            input.values["writes_bytes"] = .int(clampedInt(exception.totalWritesCaused.converted(to: .bytes).value))
            inputs.append(input)
        }
        for launch in payload.appLaunchDiagnostics ?? [] {
            var input = baseInput(.slowLaunch, launch, callStackTree: launch.callStackTree, payload: payload)
            input.values["duration_ms"] = .int(milliseconds(launch.launchDuration))
            inputs.append(input)
        }
        return inputs
    }

    /// What every diagnostic shares. Region format, process ID and bundle
    /// identifier are deliberately not copied (the process ID only matches
    /// a crash the capture already recorded).
    private static func baseInput(
        _ kind: AppHealthReport.Kind,
        _ diagnostic: MXDiagnostic,
        callStackTree: MXCallStackTree,
        payload: MXDiagnosticPayload
    ) -> MetricKitDiagnosticInput {
        let meta = diagnostic.metaData
        return MetricKitDiagnosticInput(
            kind: kind,
            payloadEnd: payload.timeStampEnd,
            appVersion: diagnostic.applicationVersion,
            appBuild: meta.applicationBuildVersion,
            osVersion: meta.osVersion,
            deviceType: meta.deviceType,
            pid: meta.pid,
            values: [
                "architecture": .string(meta.platformArchitecture),
                "low_power_mode": .bool(meta.lowPowerModeEnabled),
                "testflight": .bool(meta.isTestFlightApp),
            ],
            callStackTreeJSON: callStackTree.jsonRepresentation()
        )
    }

    private static func milliseconds(_ duration: Measurement<UnitDuration>) -> Int {
        clampedInt(duration.converted(to: .milliseconds).value)
    }

    /// `Double(Int.max)` rounds up past `Int.max`, so compare against a
    /// bound that converts exactly.
    private static func clampedInt(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return value < 9.0e18 ? Int(value) : Int.max
    }
}
#endif
