import AppKit
import RestorationStation
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(Library.self) private var library
    @Environment(ModelManager.self) private var models
    @State private var job = EpisodeJob()
    @State private var templateID: Template.ID?
    @State private var isPicking = false
    @State private var isTargeted = false
    @AppStorage("runAIExtras") private var runAIExtras = true
    @AppStorage("selectedModelIDs") private var selectedModelIDs: String = PipelineModel.allCases.map(\.rawValue).joined(separator: ",")

    private var template: Template? { library.templates.first { $0.id == templateID } }

    private var selectedModels: Set<PipelineModel> {
        get {
            let ids = Set(selectedModelIDs.split(separator: ",").map(String.init))
            let filtered = PipelineModel.allCases.filter { ids.contains($0.rawValue) }
            return filtered.isEmpty ? Set(PipelineModel.allCases) : Set(filtered)
        }
        nonmutating set {
            selectedModelIDs = newValue.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    private var effectiveModels: Set<PipelineModel> {
        guard runAIExtras else { return [] }
        return PipelineModel.normalized(selectedModels)
    }

    private var modelsAreReady: Bool {
        models.areReady(effectiveModels)
    }

    private var aiButtonTitle: String {
        if !runAIExtras || effectiveModels.isEmpty {
            return "AI Tools: Off"
        } else if effectiveModels.count == PipelineModel.allCases.count {
            return "AI Tools: All (6 of 6)"
        } else {
            return "AI Tools: \(effectiveModels.count) of \(PipelineModel.allCases.count) Active"
        }
    }

    private var statusSubtitle: String {
        if !runAIExtras || effectiveModels.isEmpty {
            return "Fast mix & master only"
        }
        if !modelsAreReady {
            return "Models need download in Models tab"
        }
        return effectiveModels.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                dropZone
                trimSection

                HStack {
                    Picker("Template", selection: $templateID) {
                        ForEach(library.templates) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 280)

                    toolSelectorMenu

                    Spacer()
                    if job.isRunning {
                        Button("Cancel", role: .cancel) { job.cancel() }
                    } else {
                        Button(runAIExtras && !effectiveModels.isEmpty && modelsAreReady ? "Make Episode" : "Make MP3") {
                            guard let template else { return }
                            do {
                                let pipeline = runAIExtras && !effectiveModels.isEmpty && modelsAreReady ? try models.pipeline() : nil
                                job.start(
                                    template: template,
                                    speakerNames: library.speakers.map(\.name),
                                    pipeline: pipeline,
                                    models: effectiveModels
                                )
                            } catch {
                                job.fail(error.localizedDescription)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!job.isReady || template == nil)
                    }
                }

                status
            }
            .padding()
        }
        .onAppear { if templateID == nil { templateID = library.templates.first?.id } }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { job.select(url) }
        }
    }

    private var toolSelectorMenu: some View {
        Menu {
            Toggle("Enable AI Tools", isOn: $runAIExtras)
            Divider()
            Section("Presets") {
                Button("All Tools (Full)") {
                    runAIExtras = true
                    selectedModels = Set(PipelineModel.allCases)
                }
                Button("Clean & Transcript") {
                    runAIExtras = true
                    selectedModels = PipelineModel.cleanAndTranscript
                }
                Button("Clean Audio Only") {
                    runAIExtras = true
                    selectedModels = PipelineModel.audioOnly
                }
                Button("None (Fast MP3)") {
                    runAIExtras = false
                }
            }
            Divider()
            Section("Selected Tools") {
                ForEach(PipelineModel.allCases) { model in
                    Toggle(isOn: Binding(
                        get: { selectedModels.contains(model) && (model != .title || MLPipelineActor.titleRuntimeAvailable) },
                        set: { enable in
                            runAIExtras = true
                            var updated = selectedModels
                            if enable {
                                updated.insert(model)
                                if model == .align || model == .title {
                                    updated.insert(.voz)
                                }
                            } else {
                                updated.remove(model)
                                if model == .voz {
                                    updated.remove(.align)
                                    updated.remove(.title)
                                }
                            }
                            selectedModels = updated
                        }
                    )) {
                        HStack {
                            Text(model.name)
                            if !model.isDownloaded {
                                Text("(Needs Download)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!runAIExtras || (model == .title && !MLPipelineActor.titleRuntimeAvailable))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: runAIExtras && !effectiveModels.isEmpty ? "sparkles" : "sparkles.slash")
                    .foregroundStyle(runAIExtras && !effectiveModels.isEmpty ? (modelsAreReady ? Color.accentColor : Color.orange) : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(aiButtonTitle)
                        .font(.subheadline.weight(.medium))
                    Text(statusSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.button)
        .disabled(job.isRunning)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            .background(RoundedRectangle(cornerRadius: 16).fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay {
                if let source = job.source {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").font(.title).foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(source.lastPathComponent).font(.title3.weight(.semibold))
                            Text("Drop a different file to replace it.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose File…") { isPicking = true }
                    }
                    .padding()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Drop the sermon or podcast audio here").font(.title3.weight(.semibold))
                        Text("WAV, MP3, M4A, or AIFF").foregroundStyle(.secondary)
                        Button("Choose File…") { isPicking = true }
                    }
                    .padding()
                }
            }
            .frame(height: job.source == nil ? 220 : 84)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: \.isAudioFile), !job.isRunning else { return false }
                job.select(url)
                return true
            } isTargeted: { isTargeted = $0 }
            .disabled(job.isRunning)
    }

    @ViewBuilder private var trimSection: some View {
        switch job.analysis {
        case .none:
            EmptyView()
        case .analyzing(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction)
                Text("Restoration Station: Detecting worship music and finding where the message starts and ends…").foregroundStyle(.secondary)
            }
        case .ready(let profile, let music, let duration, let autoTrim, let contentTrim):
            if let source = job.source {
                TrimEditor(
                    source: source,
                    profile: profile,
                    music: music,
                    sourceDuration: duration,
                    autoTrim: autoTrim,
                    contentTrim: contentTrim,
                    trim: $job.trim
                )
                .disabled(job.isRunning)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .idle:
            EmptyView()
        case .running(let update):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: update.fraction)
                Text(update.message).foregroundStyle(.secondary)
            }
        case .finished(let review):
            EpisodeReviewView(review: review)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}

/// One dropped file: find the cut points, then mix and master into a new export folder.
@MainActor @Observable
final class EpisodeJob {
    enum Analysis {
        case none
        case analyzing(Double)
        case ready(LoudnessProfile, music: MusicTimeline, duration: Double, autoTrim: TrimRange, contentTrim: TrimRange)
        case failed(String)
    }

    enum State {
        case idle
        case running(CompositionUpdate)
        case finished(EpisodeReview)
        case failed(String)
    }

    private(set) var source: URL?
    private(set) var analysis = Analysis.none
    private(set) var state = State.idle
    var trim = TrimRange(start: 0, end: 0)
    private var analysisTask: Task<Void, Never>?
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    var isReady: Bool {
        if case .ready = analysis { true } else { false }
    }

    func select(_ url: URL) {
        analysisTask?.cancel()
        source = url
        state = .idle
        analysis = .analyzing(0)
        analysisTask = Task {
            do {
                let ffmpeg = try FFmpegRunner.locate()
                let duration = try await AudioCompositionService.duration(of: url)
                async let musicTask = MusicTimeline.analyze(url)
                let profile = try await LoudnessProfile.measure(url, ffmpeg: ffmpeg, duration: duration) { f in
                    Task { @MainActor [weak self] in
                        if let self, self.source == url, case .analyzing = self.analysis { self.analysis = .analyzing(f) }
                    }
                }
                let music = await musicTask
                var contentTrim = profile.detectContent()
                contentTrim.end = min(contentTrim.end, duration)
                var autoTrim = music.sermonTrim(within: contentTrim)
                autoTrim.end = min(autoTrim.end, duration)
                guard source == url else { return }
                trim = autoTrim
                analysis = .ready(profile, music: music, duration: duration, autoTrim: autoTrim, contentTrim: contentTrim)
            } catch is CancellationError {
            } catch {
                if source == url { analysis = .failed(error.localizedDescription) }
            }
        }
    }

    func fail(_ message: String) {
        state = .failed(message)
    }

    /// With a `pipeline`: clean + mix + ML according to `models`. Without: trim + mix + master only.
    func start(
        template: Template,
        speakerNames: [String],
        pipeline: MLPipelineActor?,
        models: Set<PipelineModel> = Set(PipelineModel.allCases)
    ) {
        guard let source, isReady else { return }
        let trim = trim
        state = .running(.init(message: "Restoration Station: Getting ready…", fraction: 0))
        task = Task {
            do {
                let date = Date()
                let fallbackTitle = source.deletingPathExtension().lastPathComponent
                let folder = ExportLocation.newFolder(title: fallbackTitle, date: date)
                let output = folder.appending(path: EpisodePackageExporter.masterName)
                let onUpdate: @Sendable (CompositionUpdate) -> Void = { update in
                    Task { @MainActor [weak self] in
                        if let self, self.isRunning { self.state = .running(update) }
                    }
                }
                let package: EpisodePackage
                if let pipeline, !models.isEmpty {
                    let input = MLPipelineActor.Input(
                        source: source, trim: trim, template: template, speakerNames: speakerNames, output: output, models: models)
                    let a = try await pipeline.process(input, onUpdate: onUpdate)
                    package = EpisodePackage(analysis: a, fallbackTitle: fallbackTitle, date: date)
                } else {
                    let r = try await AudioCompositionService(ffmpeg: .locate())
                        .compose(mainAudio: source, template: template, trim: trim, to: output, onUpdate: onUpdate)
                    package = EpisodePackage(title: fallbackTitle, date: date, introOffset: r.introOffsetSeconds,
                                             mainEnd: r.plan.mainEnd, totalDuration: r.totalDurationSeconds)
                }
                // Write a first package now, so the folder is complete even if nobody edits it.
                let review = EpisodeReview(package: package, folder: folder, artworkPath: template.artworkPath)
                review.save(library: nil)
                state = .finished(review)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

private extension URL {
    var isAudioFile: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .audio)) ?? false
    }
}
