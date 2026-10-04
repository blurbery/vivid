// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS)
import MessageUI
import SwiftUI

/// Settings → Diagnostics. Lists the crash, hang and exit reports kept on
/// this device, grouped by problem, shows exactly what is sent, and sends
/// them to Vivid by email only when the person chooses to.
struct DiagnosticsSettingsView: View {
    @State private var reports: [AppHealthReport] = []
    @State private var sentIDs: Set<String> = []
    @State private var shareURL: URL?
    @State private var loaded = false
    @State private var showsDeleteConfirm = false
    /// Reloads can overlap (on appear and after every store change); only the
    /// latest may publish its export file, and older ones remove their own.
    @State private var reloadGeneration = 0
    @State private var latestPlayback: PlaybackSessionReport?

    private var groups: [AppHealthReportGroup] { AppHealthReportGroup.grouping(reports) }
    private var unsent: [AppHealthReport] { AppHealthSendState.unsent(in: reports, sentIDs: sentIDs) }
    /// New reports only, or everything again once all have been sent.
    private var toSend: [AppHealthReport] { unsent.isEmpty ? reports : unsent }

    var body: some View {
        List {
            SettingsPageHeader(title: "Diagnostics",
                               subtitle: "Crash and hang reports kept on this device.",
                               systemImage: "stethoscope")
                .settingsPageHeaderRow()
            Section {
                if let latestPlayback {
                    NavigationLink { LatestPlaybackView(report: latestPlayback) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Send Latest Playback")
                            Text(([latestPlayback.startedAt.formatted(date: .abbreviated, time: .shortened)]
                                  + (latestPlayback.headline.isEmpty ? [] : [latestPlayback.headline]))
                                .joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No playback recorded yet").foregroundStyle(.secondary)
                }
            } header: { PhoneSettingsSectionHeader("Latest Playback") }
                footer: {
                    Text("If playback looked choppy, the sound dropped out or something didn't look right, send the latest session so Vivid can see what happened. Only the most recent play is kept.")
                }
            Section {
                if reports.isEmpty {
                    Text(loaded ? "No reports" : "Loading…").foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { group in
                        NavigationLink { DiagnosticsReportGroupView(group: group) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.summary)
                                Text(groupDetail(group)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { PhoneSettingsSectionHeader("Reports") }
                footer: {
                    Text("Reports stay on this device for up to 14 days and are never uploaded automatically. They contain no titles, account details or server addresses.")
                }
            if !reports.isEmpty {
                Section {
                    DiagnosticsSendButton(title: sendTitle, reports: toSend)
                    if let shareURL {
                        ShareLink(item: shareURL) { Text("Other Options") }
                    }
                } footer: {
                    Text("Send to Vivid opens Mail with the reports attached, addressed to \(VividAbout.diagnosticsEmail). Review the message before sending. Open a report to send it on its own.")
                }
                Section {
                    Button("Delete All Reports", role: .destructive) { showsDeleteConfirm = true }
                }
            }
        }
        .settingsListChrome().navigationTitle("")
        .confirmationDialog("Delete All Reports?", isPresented: $showsDeleteConfirm, titleVisibility: .visible) {
            Button("Delete All Reports", role: .destructive) {
                Task.detached(priority: .userInitiated) {
                    AppHealthSendState.clear()
                    AppHealthStore.shared.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove every diagnostics report from this device?")
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: AppHealthStore.didChange)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaybackSessionRecorder.didChange)) { _ in
            latestPlayback = PlaybackSessionRecorder.shared.latest()
        }
        .onAppear { latestPlayback = PlaybackSessionRecorder.shared.latest() }
        .onDisappear { DiagnosticsExportFile.remove(shareURL); shareURL = nil }
    }

    private var sendTitle: String {
        switch unsent.count {
        case 0: return "Send All Again"
        case 1: return "Send 1 New Report"
        default: return "Send \(unsent.count) New Reports"
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
        reloadGeneration += 1
        let generation = reloadGeneration
        let (loadedReports, loadedSentIDs) = await Task.detached(priority: .userInitiated) {
            (AppHealthStore.shared.reports(), AppHealthSendState.sentIDs())
        }.value
        guard generation == reloadGeneration else { return }
        reports = loadedReports
        sentIDs = loadedSentIDs
        loaded = true
        // Other Options shares the same reports the send button would.
        let subset = toSend
        let url = subset.isEmpty ? nil : await Task.detached(priority: .userInitiated) {
            DiagnosticsExportFile.write(AppHealthStore.shared.exportData(subset))
        }.value
        guard generation == reloadGeneration else {
            DiagnosticsExportFile.remove(url)
            return
        }
        let previous = shareURL
        shareURL = url
        if previous != url { DiagnosticsExportFile.remove(previous) }
    }
}

private struct DiagnosticsReportGroupView: View {
    let group: AppHealthReportGroup
    @State private var sentIDs: Set<String> = []

    var body: some View {
        List {
            SettingsPageHeader(title: group.summary,
                               subtitle: [group.kind.title, group.latest.technicalCode, group.latest.issueID]
                                   .compactMap { $0 }.joined(separator: " · "),
                               systemImage: "doc.text")
                .settingsPageHeaderRow()
            Section {
                ForEach(group.reports) { report in
                    NavigationLink { DiagnosticsReportDetailView(report: report) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(report.app.version) (\(report.app.build)) · \(report.app.device)"
                                 + (report.occurrenceCount > 1 ? " · " + report.repeatSummary : "")
                                 + (sentIDs.contains(report.id) ? " · Sent" : ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { PhoneSettingsSectionHeader("Reports") }
            Section {
                DiagnosticsSendButton(
                    title: group.reports.count == 1 ? "Send This Report" : "Send These Reports",
                    reports: group.reports
                )
            }
        }
        .settingsListChrome().navigationTitle("")
        .onAppear { sentIDs = AppHealthSendState.sentIDs() }
        .onReceive(NotificationCenter.default.publisher(for: AppHealthStore.didChange)) { _ in
            sentIDs = AppHealthSendState.sentIDs()
        }
    }
}

private struct DiagnosticsReportDetailView: View {
    let report: AppHealthReport
    @State private var sent = false

    var body: some View {
        List {
            SettingsPageHeader(title: report.groupSummary,
                               subtitle: [report.recordedAt.formatted(date: .abbreviated, time: .shortened),
                                          report.technicalCode, report.issueID, sent ? "Sent" : nil]
                                   .compactMap { $0 }.joined(separator: " · "),
                               systemImage: "doc.text")
                .settingsPageHeaderRow()
            Section {
                Text(json).font(.caption.monospaced()).textSelection(.enabled)
            } header: { PhoneSettingsSectionHeader("Sent Content") }
                footer: { Text("This is exactly what is sent for this report.") }
            Section {
                DiagnosticsSendButton(title: "Send This Report", reports: [report])
            }
        }
        .settingsListChrome().navigationTitle("")
        .onAppear { sent = AppHealthSendState.sentIDs().contains(report.id) }
        .onReceive(NotificationCenter.default.publisher(for: AppHealthStore.didChange)) { _ in
            sent = AppHealthSendState.sentIDs().contains(report.id)
        }
    }

    private var json: String {
        (try? AppHealthStore.encoder.encode(AppHealthExport.Entry(report))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The latest playback session: a readable summary, then exactly what is
/// sent, then the send action.
private struct LatestPlaybackView: View {
    let report: PlaybackSessionReport
    @State private var attachment: PlaybackAttachment?
    @State private var shareURL: URL?
    @State private var mailUnavailable = false

    private struct PlaybackAttachment: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        List {
            SettingsPageHeader(title: "Latest Playback",
                               subtitle: report.startedAt.formatted(date: .abbreviated, time: .shortened),
                               systemImage: "play.rectangle")
                .settingsPageHeaderRow()
            Section {
                ForEach(Array(report.summaryRows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.label, value: row.value)
                }
            } header: { PhoneSettingsSectionHeader("Summary") }
            Section {
                Button("Send Latest Playback", action: send)
                if let shareURL { ShareLink(item: shareURL) { Text("Other Options") } }
            } footer: {
                Text("Opens Mail addressed to \(VividAbout.diagnosticsEmail) with this session attached. It contains no titles, account details or server addresses.")
            }
            Section {
                Text(json).font(.caption.monospaced()).textSelection(.enabled)
            } header: { PhoneSettingsSectionHeader("Sent Content") }
                footer: { Text("This is exactly what is sent.") }
        }
        .settingsListChrome().navigationTitle("")
        .alert("Mail unavailable", isPresented: $mailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Mail, or use Other Options to send the file to \(VividAbout.diagnosticsEmail).")
        }
        .sheet(item: $attachment) { item in
            DiagnosticsMailComposer(attachment: item.url, subject: "Vivid Playback Report") { _ in
                DiagnosticsExportFile.remove(item.url)
                attachment = nil
            }.ignoresSafeArea()
        }
        .task { shareURL = data.flatMap { DiagnosticsExportFile.write($0, name: "Vivid-Playback") } }
        .onDisappear { DiagnosticsExportFile.remove(shareURL); shareURL = nil }
    }

    private var data: Data? { PlaybackSessionRecorder.encode(report) }
    private var json: String { data.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    private func send() {
        guard MFMailComposeViewController.canSendMail() else { mailUnavailable = true; return }
        attachment = data.flatMap { DiagnosticsExportFile.write($0, name: "Vivid-Playback") }.map(PlaybackAttachment.init)
    }
}

/// Opens Mail addressed to Vivid with the given reports attached, and marks
/// them sent only when Mail reports the message as sent.
private struct DiagnosticsSendButton: View {
    let title: String
    let reports: [AppHealthReport]
    @State private var attachment: MailAttachment?
    @State private var mailUnavailable = false

    var body: some View {
        Button(title, action: send)
            .disabled(reports.isEmpty)
            .alert("Mail unavailable", isPresented: $mailUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Set up Mail, or use Other Options on the Diagnostics page to send the reports file to \(VividAbout.diagnosticsEmail).")
            }
            .sheet(item: $attachment) { attachment in
                DiagnosticsMailComposer(attachment: attachment.url) { sent in
                    if sent { AppHealthSendState.markSent(attachment.reports) }
                    DiagnosticsExportFile.remove(attachment.url)
                    self.attachment = nil
                }.ignoresSafeArea()
            }
    }

    private func send() {
        guard MFMailComposeViewController.canSendMail() else {
            mailUnavailable = true
            return
        }
        guard let url = DiagnosticsExportFile.write(AppHealthStore.shared.exportData(reports)) else { return }
        attachment = MailAttachment(url: url, reports: reports)
    }

    private struct MailAttachment: Identifiable {
        let url: URL
        let reports: [AppHealthReport]
        var id: URL { url }
    }
}

private struct DiagnosticsMailComposer: UIViewControllerRepresentable {
    let attachment: URL
    var subject = "Vivid Diagnostics"
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.setToRecipients([VividAbout.diagnosticsEmail])
        composer.setSubject(subject)
        composer.setMessageBody("", isHTML: false)
        if let data = try? Data(contentsOf: attachment) {
            composer.addAttachmentData(data, mimeType: "application/json", fileName: attachment.lastPathComponent)
        }
        composer.mailComposeDelegate = context.coordinator
        return composer
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            completion(result == .sent)
        }
    }
}

/// Temporary files for Mail and the share sheet, removed once used.
private enum DiagnosticsExportFile {
    static func write(_ data: Data, name: String = "Vivid-Diagnostics") -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day())
        // A fresh folder per export keeps the attached file name clean.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsExport-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("\(name)-\(stamp)").appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
#endif
