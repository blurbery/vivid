import SwiftUI
import Observation

/// Under the synopsis: Silo's description translation, when the server says
/// the overview is waiting for one and its AI settings allow it. Shows a
/// Translate button, or translates on its own in automatic mode, then a
/// spinner while the server works. Empty on Emby and Jellyfin, which never
/// report a pending translation.
struct DescriptionTranslationView: View {
    let viewModel: ItemDetailViewModel
    let contentId: String

    @State private var translation = DescriptionTranslationRun()

    var body: some View {
        let mode = AICapabilities.shared.metadataOnView
        // A stack, not a group: a group hands its modifiers to whichever
        // branch is showing, so a phase change would cancel the run. Only
        // leaving the page should.
        ZStack {
            if mode != .off, let target = targetLanguage {
                switch translation.phase {
                case .translating:
                    HStack(spacing: 8) {
                        ProgressView()
                            #if os(tvOS)
                            .scaleEffect(0.7)
                            #endif
                        Text("Translating…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    translateButton(target)
                case .idle:
                    if mode == .button {
                        translateButton(target)
                    } else {
                        Color.clear
                            .frame(height: 0)
                            .onAppear {
                                translation.startAutomatically(contentId: contentId, targetLanguage: target, model: viewModel)
                            }
                    }
                }
            }
        }
        .onDisappear { translation.cancel() }
    }

    private var targetLanguage: String? {
        guard let language = viewModel.detail?.pendingTranslationLanguage, !language.isEmpty else { return nil }
        return language
    }

    private func translateButton(_ target: String) -> some View {
        Button {
            translation.start(contentId: contentId, targetLanguage: target, model: viewModel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble")
                Text("Translate")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.vividPrimary)
        }
        .buttonStyle(.plain)
    }
}

/// Drives one view's translation: asks Silo to translate, then re-fetches
/// the item until the translated overview arrives or about half a minute
/// has passed. Every re-fetched item is shown as it comes.
@Observable @MainActor
private final class DescriptionTranslationRun {
    enum Phase { case idle, translating, failed }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var automaticKey: String?

    /// Seconds to wait before each re-fetch, 31 in all.
    private static let refetchDelays = [1, 2, 3, 5, 5, 5, 5, 5]

    /// Automatic mode translates once per title and language for this view.
    func startAutomatically(contentId: String, targetLanguage: String, model: ItemDetailViewModel) {
        let key = contentId + "\n" + targetLanguage
        guard automaticKey != key else { return }
        automaticKey = key
        start(contentId: contentId, targetLanguage: targetLanguage, model: model)
    }

    /// Ignored while a run is going. The run re-reads its weak references
    /// to this driver and the page's model after every wait, so either
    /// going away stops it.
    func start(contentId: String, targetLanguage: String, model: ItemDetailViewModel) {
        guard task == nil else { return }
        phase = .translating
        generation += 1
        let run = generation
        task = Task { [weak self, weak model] in
            do {
                try await VividAI.shared.translateDescription(contentId: contentId, targetLanguage: targetLanguage)
            } catch {
                self?.finish(run, as: .failed)
                return
            }
            for delay in DescriptionTranslationRun.refetchDelays {
                guard self?.isLive(run) == true else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard self?.isLive(run) == true else { return }
                guard let item = try? await VividAPI.shared.itemDetail(contentId: contentId) else { continue }
                guard self?.isLive(run) == true else { return }
                guard let model else {
                    self?.finish(run, as: .idle)
                    return
                }
                // The model publishes it and caches what it published.
                model.publishRefetchedDetail(item, contentId: contentId)
                if item.pendingTranslationLanguage == nil {
                    self?.finish(run, as: .idle)
                    return
                }
            }
            self?.finish(run, as: .failed)
        }
    }

    /// Stops the run. A failure stays shown.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if phase == .translating { phase = .idle }
    }

    private func isLive(_ run: Int) -> Bool {
        !Task.isCancelled && generation == run
    }

    /// Ends a run that is still live, so a later start works.
    private func finish(_ run: Int, as outcome: Phase) {
        guard isLive(run) else { return }
        phase = outcome
        task = nil
    }
}
