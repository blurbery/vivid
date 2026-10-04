#if os(tvOS)
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Settings → Diagnostics on Apple TV. Lists the reports kept on this Apple
/// TV, shows each one, and sends them to Vivid's diagnostics service when the
/// person chooses to. A QR code with a short summary remains as a fallback.
struct TVDiagnosticsSettingsPane: View {
    @State private var reports: [AppHealthReport] = []
    @State private var sentIDs: Set<String> = []
    @State private var loaded = false
    @State private var showsDeleteConfirm = false
    @State private var latestPlayback: PlaybackSessionReport?

    private var groups: [AppHealthReportGroup] { AppHealthReportGroup.grouping(reports) }
    private var unsent: [AppHealthReport] { AppHealthSendState.unsent(in: reports, sentIDs: sentIDs) }
    /// New reports only, or everything again once all have been sent.
    private var toSend: [AppHealthReport] { unsent.isEmpty ? reports : unsent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader("LATEST PLAYBACK")
            if let latestPlayback {
                TVSettingsGroup {
                    NavigationLink { TVLatestPlaybackPage(report: latestPlayback) } label: {
                        TVSettingsRowLabel(
                            title: "Latest Playback",
                            detail: ([latestPlayback.startedAt.formatted(date: .abbreviated, time: .shortened)]
                                     + (latestPlayback.headline.isEmpty ? [] : [latestPlayback.headline]))
                                .joined(separator: " · "))
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                }
            } else {
                TVSettingsFooter("No playback recorded yet.")
            }
            TVSettingsFooter("If playback looked choppy, the sound dropped out or something didn't look right, send the latest session so Vivid can see what happened. Only the most recent play is kept.")
            TVSettingsSectionHeader("REPORTS")
            if reports.isEmpty {
                TVSettingsFooter(loaded ? "No reports." : "Loading…")
            } else {
                TVSettingsGroup {
                    ForEach(groups) { group in
                        NavigationLink { TVDiagnosticsGroupPage(group: group) } label: {
                            TVSettingsRowLabel(title: group.summary, detail: groupDetail(group))
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                    }
                }
            }
            TVSettingsFooter("Reports stay on this Apple TV for up to 14 days and are never uploaded automatically. They contain no titles, account details or server addresses.")
            if !reports.isEmpty {
                TVSettingsGroup {
                    NavigationLink { TVDiagnosticsSendPage(reports: toSend) } label: {
                        TVSettingsRowLabel(title: "Send to Vivid", detail: unsent.isEmpty
                            ? "All reports have been sent. Send them again to \(VividAbout.diagnosticsEmail)."
                            : "Send \(unsent.count == 1 ? "1 new report" : "\(unsent.count) new reports") to \(VividAbout.diagnosticsEmail).")
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    Button { showsDeleteConfirm = true } label: {
                        TVSettingsRowLabel(title: "Delete All Reports", detail: nil)
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                }
            }
        }
        .confirmationDialog("Delete All Reports?", isPresented: $showsDeleteConfirm, titleVisibility: .visible) {
            Button("Delete All Reports", role: .destructive) {
                Task.detached(priority: .userInitiated) {
                    AppHealthSendState.clear()
                    AppHealthStore.shared.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove every diagnostics report from this Apple TV?")
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: AppHealthStore.didChange)) { _ in
            Task { await reload() }
        }
        .onAppear { latestPlayback = PlaybackSessionRecorder.shared.latest() }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackSessionRecorder.didChange)) { _ in
            latestPlayback = PlaybackSessionRecorder.shared.latest()
        }
    }

    private func groupDetail(_ group: AppHealthReportGroup) -> String {
        let latest = group.latest.lastOccurredAt.formatted(.relative(presentation: .named))
        let count = group.reports.count == 1 ? "1 report" : "\(group.reports.count) reports"
        let times = group.occurrenceCount > group.reports.count ? " · happened \(group.occurrenceCount) times" : ""
        let allSent = group.reports.allSatisfy { sentIDs.contains($0.id) }
        return "\(group.kind.title) · \(count)\(times) · latest \(latest) · \(group.latest.issueID)" + (allSent ? " · Sent" : "")
    }

    private func reload() async {
        (reports, sentIDs) = await Task.detached(priority: .userInitiated) {
            (AppHealthStore.shared.reports(), AppHealthSendState.sentIDs())
        }.value
        loaded = true
    }
}

private struct TVDiagnosticsGroupPage: View {
    let group: AppHealthReportGroup

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                TVSettingsPageHeader(
                    title: group.summary,
                    subtitle: [group.kind.title, group.latest.technicalCode, group.latest.issueID]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                TVSettingsGroup {
                    ForEach(group.reports) { report in
                        NavigationLink { TVDiagnosticsReportPage(report: report) } label: {
                            TVSettingsRowLabel(
                                title: report.recordedAt.formatted(date: .abbreviated, time: .shortened),
                                detail: "\(report.app.version) (\(report.app.build)) · \(report.app.device)"
                                    + (report.occurrenceCount > 1 ? " · " + report.repeatSummary : "")
                            )
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                    }
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
    }
}

/// A reading page. Each section is focusable so the remote can scroll it,
/// following the Privacy Policy page.
private struct TVDiagnosticsReportPage: View {
    let report: AppHealthReport
    @FocusState private var focusedSection: Int?

    private var sections: [(title: String, lines: [String])] {
        var sections: [(String, [String])] = []
        var summary = [
            "Issue ID: \(report.issueID)",
            "When: \(report.recordedAt.formatted(date: .abbreviated, time: .standard))",
        ]
        if report.occurrenceCount > 1 { summary.append(report.repeatSummary) }
        summary += [
            "App: \(report.app.version) (\(report.app.build)) on \(report.app.os), \(report.app.device)",
        ]
        if let code = report.technicalCode { summary.append("Code: \(code)") }
        sections.append(("Summary", summary))
        if let context = report.context, !context.isEmpty {
            sections.append(("What was happening", Self.lines(context)))
        }
        if !report.details.isEmpty {
            sections.append(("Details", Self.lines(report.details)))
        }
        let events = report.recentEvents ?? []
        // Small blocks so each focus step scrolls a readable amount.
        stride(from: 0, to: events.count, by: 8).forEach { start in
            let block = Array(events[start..<min(start + 8, events.count)])
            sections.append((start == 0 ? "Recent events" : "Recent events (continued)", block))
        }
        if report.callStackTree != nil {
            sections.append(("Call stack", ["Included in the full report for symbolication."]))
        }
        return sections
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                TVSettingsPageHeader(title: report.groupSummary, subtitle: report.kind.title)
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.system(size: 27, weight: .semibold))
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 20, design: .monospaced)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(focusedSection == index ? 0.85 : 0), lineWidth: 2)
                    }
                    .focusable()
                    .focused($focusedSection, equals: index)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focusedSection, 0)
    }

    private static func lines(_ values: [String: DiagnosticsJSONValue]) -> [String] {
        values.keys.sorted().compactMap { key in
            switch values[key] {
            case .string(let text): return "\(key): \(text)"
            case .int(let number): return "\(key): \(number)"
            case .double(let number): return "\(key): \(number)"
            case .bool(let flag): return "\(key): \(flag ? "yes" : "no")"
            default: return nil
            }
        }
    }
}

/// The latest playback session as a reading page: summary, the minutes
/// that had problems, and what couldn't be measured.
private struct TVLatestPlaybackPage: View {
    let report: PlaybackSessionReport
    @FocusState private var focusedSection: Int?
    @FocusState private var sendFocused: Bool
    @State private var status: DiagnosticsSendStatus = .idle

    private var sections: [(title: String, lines: [String])] {
        var sections: [(String, [String])] = [
            ("Summary", report.summaryRows.map { "\($0.label): \($0.value)" }),
            ("App", ["\(report.app.version) (\(report.app.build)) on \(report.app.os), \(report.app.device)"]),
        ]
        let minutes = report.timeline.map { minute -> String in
            var parts: [String] = []
            if minute.droppedFrames > 0 { parts.append("\(minute.droppedFrames) dropped") }
            if minute.decoderDroppedFrames > 0 { parts.append("\(minute.decoderDroppedFrames) decoder dropped") }
            if minute.delayedFrames > 0 { parts.append("\(minute.delayedFrames) late") }
            if let sync = minute.maxAvSyncMs, sync > 100 { parts.append("A/V sync \(Int(sync)) ms") }
            if minute.rebufferSeconds > 0 { parts.append("rebuffering \(Int(minute.rebufferSeconds)) s") }
            if minute.stallSeconds > 0 { parts.append("stalled \(Int(minute.stallSeconds)) s") }
            for (fault, count) in minute.faults.sorted(by: { $0.key < $1.key }) { parts.append("\(fault) ×\(count)") }
            return "Minute \(minute.minute): " + parts.joined(separator: ", ")
        }
        stride(from: 0, to: minutes.count, by: 8).forEach { start in
            sections.append((start == 0 ? "When it happened" : "When it happened (continued)",
                             Array(minutes[start..<min(start + 8, minutes.count)])))
        }
        return sections
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                TVSettingsPageHeader(title: "Latest Playback",
                                     subtitle: report.startedAt.formatted(date: .abbreviated, time: .shortened))
                TVSettingsGroup {
                    TVDiagnosticsSendRow(title: "Send Latest Playback", status: status, action: send)
                        .focused($sendFocused)
                }
                TVSettingsFooter("Sends this session to Vivid, where it's emailed to \(VividAbout.diagnosticsEmail) and kept for 30 days. It contains no titles, account details or server addresses.")
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.system(size: 27, weight: .semibold))
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 20, design: .monospaced)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(focusedSection == index ? 0.85 : 0), lineWidth: 2)
                    }
                    .focusable()
                    .focused($focusedSection, equals: index)
                    .focusEffectDisabled()
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($sendFocused, true)
    }

    private func send() {
        guard !status.isSending, let data = PlaybackSessionRecorder.encode(report) else { return }
        status = .sending
        Task {
            do {
                status = .sent(reference: try await DiagnosticsUploader.send(data, kind: .playback))
            } catch {
                status = .failed(error as? DiagnosticsUploader.Failure ?? .unavailable)
            }
        }
    }
}

/// A send row whose detail shows progress and the result.
private struct TVDiagnosticsSendRow: View {
    let title: String
    let status: DiagnosticsSendStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVSettingsRowLabel(title: retryable ? "Try Again" : title, detail: status.detail)
        }
        // Stays enabled while sending: a disabled control can't hold focus on
        // tvOS, so focus would jump away. The send actions ignore repeats.
        .buttonStyle(TVSettingsPaneRowStyle())
    }

    private var retryable: Bool { if case .failed(let failure) = status { return failure.canRetry } else { return false } }
}

/// What will be sent, the Send button, and the QR code as a fallback.
private struct TVDiagnosticsSendPage: View {
    /// Fixed when the page opens, so marking them sent can't swap the list.
    @State private var reports: [AppHealthReport]
    @State private var status: DiagnosticsSendStatus = .idle
    @FocusState private var sendFocused: Bool

    init(reports: [AppHealthReport]) { _reports = State(initialValue: reports) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                TVSettingsPageHeader(title: "Send to Vivid",
                                     subtitle: reports.count == 1 ? "1 report" : "\(reports.count) reports")
                TVSettingsGroup {
                    TVDiagnosticsSendRow(title: "Send", status: status, action: send)
                        .focused($sendFocused)
                    NavigationLink { TVDiagnosticsQRPage(reports: reports) } label: {
                        TVSettingsRowLabel(title: "Show QR Code", detail: "Scan with your phone to email a short summary instead.")
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                }
                TVSettingsFooter("Sends these reports to Vivid, where they're emailed to \(VividAbout.diagnosticsEmail) and kept for 30 days. Open a report in Diagnostics to see exactly what it contains.")
                TVSettingsSectionHeader("WHAT IS SENT")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AppHealthReportGroup.grouping(reports)) { group in
                        Text(TVDiagnosticsQRCode.summaryLine(for: group))
                            .font(.system(size: 20, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .tvSettingsPageSurface()
        .defaultFocus($sendFocused, true)
    }

    private func send() {
        guard !status.isSending, !reports.isEmpty else { return }
        status = .sending
        let reports = reports
        Task {
            let data = await Task.detached(priority: .userInitiated) { AppHealthStore.shared.exportData(reports) }.value
            do {
                let reference = try await DiagnosticsUploader.send(data, kind: .problems)
                AppHealthSendState.markSent(reports)
                status = .sent(reference: reference)
            } catch {
                status = .failed(error as? DiagnosticsUploader.Failure ?? .unavailable)
            }
        }
    }
}

private struct TVDiagnosticsQRPage: View {
    let reports: [AppHealthReport]

    var body: some View {
        let code = TVDiagnosticsQRCode.make(for: reports)
        VStack(spacing: 28) {
            Text("Send by QR Code").font(.system(size: 42, weight: .bold, design: .rounded))
            if let image = code.image {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 420, height: 420).padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Scan to email a diagnostics summary to Vivid")
            }
            Text("Scan with your phone to open an email with a summary of these reports. Review it before sending.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
            if code.omittedGroups > 0 {
                Text("\(code.omittedGroups) older \(code.omittedGroups == 1 ? "problem" : "problems") didn’t fit in the code.")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
            }
            Text(VividAbout.diagnosticsEmail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvSettingsPageSurface()
    }
}

/// A `mailto:` link small enough for a scannable QR code, summarising each
/// group of reports in one line.
enum TVDiagnosticsQRCode {
    /// Low error correction holds about 2.9 KB; stay well under it so the
    /// code stays scannable from across a room.
    static let maxURLBytes = 1_800

    struct Result {
        let image: UIImage?
        let omittedGroups: Int
    }

    static func make(for reports: [AppHealthReport]) -> Result {
        let (url, omitted) = mailURL(for: reports)
        guard let url else { return Result(image: nil, omittedGroups: omitted) }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return Result(image: nil, omittedGroups: omitted)
        }
        return Result(image: UIImage(cgImage: cgImage), omittedGroups: omitted)
    }

    /// The most recent app events added for each problem when they fit.
    static let maxEventLines = 12

    /// Each problem gets its summary line and a line of facts (what was
    /// happening, memory use, cause). Whatever room is left goes to the
    /// app events that led up to the newest problems, latest events first.
    static func mailURL(for reports: [AppHealthReport]) -> (URL?, omitted: Int) {
        let groups = AppHealthReportGroup.grouping(reports)
        let app = AppHealthAppInfo.current
        let header = "Vivid diagnostics from Apple TV\nApp \(app.version) (\(app.build)) · \(app.os) · \(app.device)\n"
        func url(_ blocks: [[String]]) -> URL? {
            VividAbout.mailURL(
                subject: "Vivid Diagnostics",
                message: header + blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n"),
                to: VividAbout.diagnosticsEmail
            )
        }
        func fits(_ blocks: [[String]]) -> Bool {
            url(blocks).map { $0.absoluteString.utf8.count <= maxURLBytes } ?? false
        }

        var blocks: [[String]] = []
        for group in groups {
            let summary = summaryLine(for: group)
            let facts = factsLine(for: group.latest)
            if let facts, fits(blocks + [[summary, facts]]) {
                blocks.append([summary, facts])
            } else if fits(blocks + [[summary]]) {
                blocks.append([summary])
            } else {
                break
            }
        }
        for (index, group) in groups.prefix(blocks.count).enumerated() {
            let events = Array((group.latest.recentEvents ?? []).suffix(maxEventLines))
            guard !events.isEmpty else { continue }
            var count = 0
            while count < events.count {
                var candidate = blocks
                candidate[index] = blocks[index] + ["Events:"] + events.suffix(count + 1)
                guard fits(candidate) else { break }
                count += 1
            }
            if count > 0 { blocks[index] += ["Events:"] + events.suffix(count) }
        }
        return (url(blocks), groups.count - blocks.count)
    }

    static func summaryLine(for group: AppHealthReportGroup) -> String {
        let date = group.latest.lastOccurredAt.formatted(.iso8601.year().month().day())
        return [group.latest.issueID, group.summary, group.latest.technicalCode, "x\(group.occurrenceCount)", date]
            .compactMap { $0 }
            .joined(separator: " | ")
    }

    /// The report's context and details as compact `key=value` pairs, without
    /// the process ID and timestamps that only matter on the device.
    static func factsLine(for report: AppHealthReport) -> String? {
        let skipped: Set<String> = ["pid", "session_started"]
        let values = (report.context ?? [:]).merging(report.details) { context, _ in context }
        let pairs = values.keys.sorted().filter { !skipped.contains($0) }.compactMap { key -> String? in
            switch values[key] {
            case .string(let text): return "\(key)=\(text)"
            case .int(let number): return "\(key)=\(number)"
            case .double(let number): return "\(key)=\(number)"
            case .bool(let flag): return "\(key)=\(flag)"
            default: return nil
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: " ")
    }
}
#endif
