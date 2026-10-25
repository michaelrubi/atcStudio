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

    private var template: Template? { library.templates.first { $0.id == templateID } }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                dropZone
                trimSection

                HStack {
                    Picker("Template", selection: $templateID) {
                        ForEach(library.templates) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 320)
                    Toggle(isOn: Binding(get: { runAIExtras && models.allReady }, set: { runAIExtras = $0 })) {
                        Text("Clean audio, transcript, speakers, and titles")
                        Text(models.allReady ? "Turn off to make only the MP3, faster."
                                             : "Download the models in the Models tab to use this.")
                    }
                    .disabled(!models.allReady || job.isRunning)
                    Spacer()
                    if job.isRunning {
                        Button("Cancel", role: .cancel) { job.cancel() }
                    } else {
                        Button(runAIExtras && models.allReady ? "Make Episode" : "Make MP3") {
                            guard let template else { return }
                            do {
                                try job.start(template: template, speakerNames: library.speakers.map(\.name),
                                              pipeline: runAIExtras && models.allReady ? models.pipeline() : nil)
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
                Text("Restoration Station: Finding where the message starts and ends…").foregroundStyle(.secondary)
            }
        case .ready(let profile, let duration, let autoTrim):
            if let source = job.source {
                TrimEditor(source: source, profile: profile, sourceDuration: duration,
                           autoTrim: autoTrim, trim: $job.trim)
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
        case .finished(let outcome):
            let result = outcome.analysis
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Restoration Station: Your episode is ready.", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    LabeledContent("Length", value: Timecode.string(outcome.totalDuration))
                    LabeledContent("Message starts at", value: Timecode.string(outcome.introOffset, millis: true))
                    LabeledContent("Outro starts at", value: Timecode.string(outcome.mainEnd))
                    if let result {
                        LabeledContent("Speakers found", value: "\(result.speakerCount)")
                        LabeledContent("Filler words", value: "\(result.fillers.count)")
                        LabeledContent("Words", value: "\(result.words.count)")
                        if !result.suggestedTitles.isEmpty {
                            LabeledContent("Title ideas") {
                                VStack(alignment: .trailing) {
                                    ForEach(result.suggestedTitles, id: \.self) { Text($0) }
                                }
                            }
                        }
                        if !result.summary.isEmpty {
                            LabeledContent("Summary") { Text(result.summary).multilineTextAlignment(.trailing) }
                        }
                        Text(result.transcriptText.prefix(600) + (result.transcriptText.count > 600 ? "…" : ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([outcome.masterURL])
                        }
                        Button("Play") { NSWorkspace.shared.open(outcome.masterURL) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
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
        case ready(LoudnessProfile, duration: Double, autoTrim: TrimRange)
        case failed(String)
    }

    /// The MP3 always; the ML analysis only when the AI extras ran.
    struct Outcome {
        var masterURL: URL
        var introOffset: Double
        var mainEnd: Double
        var totalDuration: Double
        var analysis: EpisodeAnalysis?
    }

    enum State {
        case idle
        case running(CompositionUpdate)
        case finished(Outcome)
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
                let profile = try await LoudnessProfile.measure(url, ffmpeg: ffmpeg, duration: duration) { f in
                    Task { @MainActor [weak self] in
                        if let self, self.source == url, case .analyzing = self.analysis { self.analysis = .analyzing(f) }
                    }
                }
                var auto = profile.detectContent()
                auto.end = min(auto.end, duration)
                guard source == url else { return }
                trim = auto
                analysis = .ready(profile, duration: duration, autoTrim: auto)
            } catch is CancellationError {
            } catch {
                if source == url { analysis = .failed(error.localizedDescription) }
            }
        }
    }

    func fail(_ message: String) {
        state = .failed(message)
    }

    /// With a `pipeline`: clean + mix + ML. Without: trim + mix + master only (no models needed).
    func start(template: Template, speakerNames: [String], pipeline: MLPipelineActor?) {
        guard let source, isReady else { return }
        let trim = trim
        state = .running(.init(message: "Restoration Station: Getting ready…", fraction: 0))
        task = Task {
            do {
                let folder = ExportLocation.newFolder(title: source.deletingPathExtension().lastPathComponent)
                let output = folder.appending(path: "master_episode.mp3")
                let onUpdate: @Sendable (CompositionUpdate) -> Void = { update in
                    Task { @MainActor [weak self] in
                        if let self, self.isRunning { self.state = .running(update) }
                    }
                }
                if let pipeline {
                    let input = MLPipelineActor.Input(
                        source: source, trim: trim, template: template, speakerNames: speakerNames, output: output)
                    let a = try await pipeline.process(input, onUpdate: onUpdate)
                    state = .finished(Outcome(masterURL: a.masterURL, introOffset: a.introOffset,
                                              mainEnd: a.mainEnd, totalDuration: a.totalDuration, analysis: a))
                } else {
                    let r = try await AudioCompositionService(ffmpeg: .locate())
                        .compose(mainAudio: source, template: template, trim: trim, to: output, onUpdate: onUpdate)
                    state = .finished(Outcome(masterURL: r.outputURL, introOffset: r.introOffsetSeconds,
                                              mainEnd: r.plan.mainEnd, totalDuration: r.totalDurationSeconds,
                                              analysis: nil))
                }
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
