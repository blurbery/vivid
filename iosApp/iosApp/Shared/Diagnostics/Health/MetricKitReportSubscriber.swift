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

    private func ingest(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for input in Self.inputs(from: payload) {
                let report = MetricKitReportSummariser.report(from: input)
                if input.kind == .crash, let pid = input.pid,
                   AppHealthStore.shared.merge(metricKitCrash: report, pid: Int(pid)) {
                    continue
                }
                AppHealthStore.shared.add(report)
            }
        }
    }

    private static func inputs(from payload: MXDiagnosticPayload) -> [MetricKitDiagnosticInput] {
        var inputs: [MetricKitDiagnosticInput] = []
        for crash in payload.crashDiagnostics ?? [] {
            var input = baseInput(.crash, crash, payload: payload)
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
            input.callStackTreeJSON = crash.callStackTree.jsonRepresentation()
            inputs.append(input)
        }
        for hang in payload.hangDiagnostics ?? [] {
            var input = baseInput(.hang, hang, payload: payload)
            input.values["duration_ms"] = .int(milliseconds(hang.hangDuration))
            input.callStackTreeJSON = hang.callStackTree.jsonRepresentation()
            inputs.append(input)
        }
        for exception in payload.cpuExceptionDiagnostics ?? [] {
            var input = baseInput(.cpuException, exception, payload: payload)
            input.values["cpu_time_ms"] = .int(milliseconds(exception.totalCPUTime))
            input.values["sampled_time_ms"] = .int(milliseconds(exception.totalSampledTime))
            input.callStackTreeJSON = exception.callStackTree.jsonRepresentation()
            inputs.append(input)
        }
        for exception in payload.diskWriteExceptionDiagnostics ?? [] {
            var input = baseInput(.diskWriteException, exception, payload: payload)
            let bytes = exception.totalWritesCaused.converted(to: .bytes).value
            input.values["writes_bytes"] = .int(clampedInt(bytes))
            input.callStackTreeJSON = exception.callStackTree.jsonRepresentation()
            inputs.append(input)
        }
        for launch in payload.appLaunchDiagnostics ?? [] {
            var input = baseInput(.slowLaunch, launch, payload: payload)
            input.values["duration_ms"] = .int(milliseconds(launch.launchDuration))
            input.callStackTreeJSON = launch.callStackTree.jsonRepresentation()
            inputs.append(input)
        }
        return inputs
    }

    /// Region format, process ID and bundle identifier are deliberately not
    /// copied.
    private static func baseInput(
        _ kind: AppHealthReport.Kind,
        _ diagnostic: MXDiagnostic,
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
            ]
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
