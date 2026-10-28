import AppKit
import RestorationStation
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(Library.self) private var library
    @Environment(ModelManager.self) private var models
    @Environment(EpisodeJob.self) private var job
    @State private var step = WorkspaceStep.add
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
        VStack(spacing: 0) {
            StepBar(current: $step, isReachable: isReachable)
                .disabled(job.isRunning)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case .add:
                        dropZone
                        RecentEpisodesList { folder in
                            if let review = EpisodeReview(reopening: folder) {
                                job.open(review)
                                step = .review
                            }
                        }
                    case .trim: trimStep
                    case .make: makeStep
                    case .review: reviewStep
                    }
                }
                .padding()
            }
        }
        .onAppear { if templateID == nil { templateID = library.templates.first?.id } }
        .onChange(of: job.isFinished) { _, finished in if finished { step = .review } }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { select(url) }
        }
    }

    private func isReachable(_ step: WorkspaceStep) -> Bool {
        switch step {
        case .add: true
        case .trim: job.source != nil
        case .make: job.isReady
        case .review: job.isFinished
        }
    }

    private func select(_ url: URL) {
        job.select(url)
        step = .trim
    }

    // MARK: - Steps

    private var trimStep: some View {
        VStack(spacing: 20) {
            dropZone
            trimSection
            HStack {
                Spacer()
                Button("Continue") { step = .make }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!job.isReady)
            }
        }
    }

    private var makeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let source = job.source {
                LabeledContent("Audio", value: source.lastPathComponent)
                LabeledContent("Message length", value: Timecode.string(job.trim.duration))
            }
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
                    Button("Make Episode") {
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
                    .keyboardShortcut(.defaultAction)
                    .disabled(!job.isReady || template == nil)
                    .help(runAIExtras && !effectiveModels.isEmpty && modelsAreReady
                          ? "Clean, mix, and master with the selected AI tools"
                          : "Fast mode: trim, mix, and master only (no AI tools)")
                }
            }
            status
        }
    }

    @ViewBuilder private var reviewStep: some View {
        status
        HStack {
            Spacer()
            Button("Start New Episode", systemImage: "plus") {
                job.reset()
                step = .add
            }
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
                select(url)
                return true
            } isTargeted: { isTargeted = $0 }
            .disabled(job.isRunning)
    }

    @ViewBuilder private var trimSection: some View {
        @Bindable var job = job
        switch job.analysis {
        case .none:
            EmptyView()
        case .analyzing(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction)
                Text("Detecting worship music and finding where the message starts and ends…").foregroundStyle(.secondary)
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

    var isFinished: Bool {
        if case .finished = state { true } else { false }
    }

    /// Shows a past episode's review. There is no source file, so Trim and Make stay locked.
    func open(_ review: EpisodeReview) {
        reset()
        state = .finished(review)
    }

    /// Back to an empty workspace for the next file. The finished episode stays in its export folder.
    func reset() {
        analysisTask?.cancel()
        task?.cancel()
        source = nil
        analysis = .none
        state = .idle
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
        state = .running(.init(message: "Getting ready…", fraction: 0))
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

enum WorkspaceStep: Int, CaseIterable {
    case add, trim, make, review

    var title: String {
        switch self {
        case .add: "Add Audio"
        case .trim: "Trim"
        case .make: "Make"
        case .review: "Review & Publish"
        }
    }
}

/// The four Workspace steps. A step is clickable once the work before it is done.
private struct StepBar: View {
    @Binding var current: WorkspaceStep
    let isReachable: (WorkspaceStep) -> Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WorkspaceStep.allCases, id: \.self) { step in
                if step != .add {
                    Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: 40)
                }
                Button { current = step } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(fill(for: step)).frame(width: 22, height: 22)
                            if step.rawValue < current.rawValue && isReachable(step) {
                                Image(systemName: "checkmark").font(.caption.bold())
                            } else {
                                Text("\(step.rawValue + 1)").font(.caption.bold())
                            }
                        }
                        .foregroundStyle(step == current ? .white : .primary)
                        Text(step.title)
                            .fontWeight(step == current ? .semibold : .regular)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isReachable(step))
                .opacity(isReachable(step) ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func fill(for step: WorkspaceStep) -> AnyShapeStyle {
        step == current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
    }
}

/// Past episodes from the export folder, newest first, so a volunteer can fix or publish one later.
private struct RecentEpisodesList: View {
    struct Item: Identifiable {
        var folder: URL
        var title: String
        var date: Date
        var duration: Double
        var published: PublishResult?
        var id: URL { folder }
    }

    let onOpen: (URL) -> Void
    @State private var items: [Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                Text("Recent Episodes").font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if item.id != items.first?.id { Divider() }
                        row(item)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            items = await Task.detached {
                EpisodePackage.recent().map {
                    Item(folder: $0.folder, title: $0.package.title, date: $0.package.date,
                         duration: $0.package.totalDuration, published: PublishResult.load(from: $0.folder))
                }
            }.value
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                Text("\(item.date.formatted(date: .abbreviated, time: .omitted)) · \(Timecode.string(item.duration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let published = item.published {
                Label(published.status == .draft ? "Draft on PodBean" : "Published", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("Not published").font(.callout).foregroundStyle(.secondary)
            }
            Button("Open") { onOpen(item.folder) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
