// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import SwiftUI
#if os(iOS)
import MessageUI
#elseif os(tvOS)
import CoreImage.CIFilterBuiltins
import UIKit
#endif

private enum VividAbout {
    static let email = "admin@vividapp.co"
    static let website = URL(string: "https://vividapp.co")!
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
    static func mailURL(subject: String, message: String) -> URL? {
        var url = URLComponents()
        url.scheme = "mailto"
        url.path = email
        url.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: message)]
        return url.url
    }
}

struct AboutSettingsView: View {
    #if os(tvOS)
    @State private var showsPrivacy = false
    @State private var showsLicenses = false
    #endif

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Image("AboutInfoIcon").resizable().scaledToFit().frame(width: 42, height: 42)
                    Text("About").font(.system(size: 42, weight: .bold, design: .rounded))
                }
                brand
                TVSettingsGroup {
                    Button { showsLicenses = true } label: {
                        TVSettingsRowLabel(title: "Open Source Licences")
                    }.buttonStyle(TVSettingsPaneRowStyle())
                    NavigationLink { ServiceAcknowledgementsView() } label: {
                        TVSettingsRowLabel(title: "Acknowledgements")
                    }.buttonStyle(TVSettingsPaneRowStyle())
                    Button { showsPrivacy = true } label: {
                        TVSettingsRowLabel(title: "Privacy Policy")
                    }.buttonStyle(TVSettingsPaneRowStyle())
                    NavigationLink { VividContactSettingsView() } label: {
                        TVSettingsRowLabel(title: "Contact", detail: VividAbout.email)
                    }.buttonStyle(TVSettingsPaneRowStyle())
                }
                VividCopyrightFooter().frame(maxWidth: .infinity)
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth).padding(24).frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .fullScreenCover(isPresented: $showsPrivacy) {
            TVPrivacyPolicyOverlay { showsPrivacy = false }
        }
        .fullScreenCover(isPresented: $showsLicenses) {
            TVOpenSourceAcknowledgementsOverlay { showsLicenses = false }
        }
        #else
        List {
            SettingsPageHeader(title: "About", subtitle: "Vivid for your Apple devices.",
                               systemImage: "info.circle", imageName: "AboutInfoIcon")
                .settingsPageHeaderRow()
            brand.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                NavigationLink("Open Source Licences") { OpenSourceAcknowledgementsView() }
                NavigationLink("Acknowledgements") { ServiceAcknowledgementsView() }
                #if os(iOS)
                NavigationLink("Privacy Policy") { PhoneVividPrivacyView() }
                #else
                Link("Privacy Policy", destination: VividAbout.website.appendingPathComponent("privacy"))
                #endif
                NavigationLink("Contact") { VividContactSettingsView() }
                Link(destination: VividAbout.website) {
                    HStack {
                        Text("Website")
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                }
            }
            Text("© 2026 Vivid™").font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .settingsListChrome().navigationTitle("")
        #endif
    }

    private var brand: some View {
        VStack(spacing: 12) {
            VividMarkView(width: 112)
            Text("Vivid").font(.system(size: 36, weight: .semibold, design: .rounded))
            Text(VividAbout.version).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }


}

private struct VividContactSettingsView: View {
    #if os(tvOS)
    private static let mailImage: UIImage? = {
        guard let url = VividAbout.mailURL(subject: "Vivid Support", message: "") else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }()

    var body: some View {
        VStack(spacing: 28) {
            Text("Contact").font(.system(size: 42, weight: .bold, design: .rounded))
            if let image = Self.mailImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 300, height: 300).padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Scan to email Vivid support")
            }
            Text("Scan with your phone to open an email form.").foregroundStyle(.secondary)
            Text(VividAbout.email)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("")
    }
    #else
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var subject = "Vivid Support"
    @State private var message = ""
    @State private var showsComposer = false
    @State private var mailUnavailable = false

    var body: some View {
        List {
            SettingsPageHeader(title: "Contact", subtitle: "Send a message to Vivid support.", systemImage: "envelope")
                .settingsPageHeaderRow()
            Section {
                LabeledContent("To", value: VividAbout.email)
                TextField("Subject", text: $subject)
                    .accessibilityLabel("Subject")
            }
            Section {
                TextEditor(text: $message).frame(minHeight: 180)
                    .accessibilityLabel("Message")
            } header: { PhoneSettingsSectionHeader("Message") }
                footer: { Text("Review and send your message in Mail. No logs or account details are attached.") }

            Section {
                Button("Continue in Mail", action: compose)
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .settingsListChrome().navigationTitle("")
        .alert("Mail unavailable", isPresented: $mailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up an email app, then send your message to \(VividAbout.email).")
        }
        #if os(iOS)
        .sheet(isPresented: $showsComposer) {
            VividMailComposer(subject: subject, message: message) { sent, failed in
                showsComposer = false
                if sent { dismiss() }
                if failed { mailUnavailable = true }
            }.ignoresSafeArea()
        }
        #endif
    }

    private func compose() {
        #if os(iOS)
        if MFMailComposeViewController.canSendMail() {
            showsComposer = true
            return
        }
        #endif
        guard let url = VividAbout.mailURL(subject: subject, message: message) else {
            mailUnavailable = true
            return
        }
        openURL(url) { accepted in if !accepted { mailUnavailable = true } }
    }
    #endif
}

#if os(iOS)
private struct VividMailComposer: UIViewControllerRepresentable {
    let subject: String
    let message: String
    let completion: (Bool, Bool) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.setToRecipients([VividAbout.email])
        composer.setSubject(subject)
        composer.setMessageBody(message, isHTML: false)
        composer.mailComposeDelegate = context.coordinator
        return composer
    }
    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let completion: (Bool, Bool) -> Void
        init(completion: @escaping (Bool, Bool) -> Void) { self.completion = completion }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            completion(result == .sent, result == .failed || error != nil)
        }
    }
}
#endif
