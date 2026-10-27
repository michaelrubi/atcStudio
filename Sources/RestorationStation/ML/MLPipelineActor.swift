import Align
import Clear
import Foundation
import Title
import Uhm
import Voz
import Who

/// Runs one episode end to end:
/// cut → `Clear` → bumper mix + master → `Who` → `Voz` → `Align` → `Uhm` → `Title`,
/// then shifts every timestamp by the intro offset.
///
/// Models are loaded once and reused across runs. An actor, so only one run uses them at a time.
public actor MLPipelineActor {
    public struct Input: Sendable {
        public var source: URL
        public var trim: TrimRange
        public var template: Template
        /// Saved speaker names, passed to `Voz` with the template vocabulary.
        public var speakerNames: [String]
        public var output: URL
        public var models: Set<PipelineModel>

        public init(
            source: URL,
            trim: TrimRange,
            template: Template,
            speakerNames: [String],
            output: URL,
            models: Set<PipelineModel> = Set(PipelineModel.allCases)
        ) {
            self.source = source
            self.trim = trim
            self.template = template
            self.speakerNames = speakerNames
            self.output = output
            self.models = models
        }
    }

    /// Speakers with less than this share of talk time are folded away (coughs, a "thank you").
    static let minimumSpeakerShare = 0.01
    /// Title reads at most this many words (its window is 32k tokens).
    static let titleWordLimit = 15_000
    static let languageCode = "en"

    private let ffmpeg: FFmpegRunner
    private let clear = Clear()
    private let who = Who()
    private let align = Align()
    private let uhm = Uhm()
    private var voz: Voz?
    private var titles: Titles?

    public init(ffmpeg: FFmpegRunner) {
        self.ffmpeg = ffmpeg
    }

    // MARK: - Run

    public func process(
        _ input: Input,
        onUpdate: @escaping @Sendable (CompositionUpdate) -> Void = { _ in }
    ) async throws -> EpisodeAnalysis {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "ATCStudio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let activeModels = PipelineModel.normalized(input.models)

        // Dynamic progress calculation based on active models.
        var stageWeights: [(id: String, weight: Double)] = [("trim", 2)]
        if activeModels.contains(.clear) { stageWeights.append(("clear", 23)) }
        stageWeights.append(("mix", 20))
        if activeModels.contains(.who) { stageWeights.append(("who", 10)) }
        if activeModels.contains(.voz) { stageWeights.append(("voz", 25)) }
        if activeModels.contains(.align) && activeModels.contains(.voz) { stageWeights.append(("align", 5)) }
        if activeModels.contains(.uhm) { stageWeights.append(("uhm", 7)) }
        if activeModels.contains(.title) && activeModels.contains(.voz) && Self.titleRuntimeAvailable {
            stageWeights.append(("title", 8))
        }

        let totalWeight = max(1.0, stageWeights.reduce(0) { $0 + $1.weight })
        var stageRanges: [String: ClosedRange<Double>] = [:]
        var accum = 0.0
        for (id, weight) in stageWeights {
            let next = accum + weight / totalWeight
            stageRanges[id] = accum...next
            accum = next
        }

        func stage(_ id: String, _ message: String) -> @Sendable (Double) -> Void {
            let range = stageRanges[id] ?? 0...1
            onUpdate(.init(message: message, fraction: range.lowerBound))
            return { f in
                onUpdate(.init(message: message,
                               fraction: range.lowerBound + min(1, max(0, f)) * (range.upperBound - range.lowerBound)))
            }
        }

        // 1. Cut the kept part. Clean it only if `Clear` is active.
        let cut = work.appending(path: "main_cut.wav")
        let cutting = stage("trim", "Trimming the message…")
        try await ffmpeg.run([
            "-i", input.source.path, "-map", "0:a:0",
            "-af", "atrim=start=\(seconds(input.trim.start)):end=\(seconds(input.trim.end)),asetpts=PTS-STARTPTS",
            "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", "-y", cut.path,
        ], duration: input.trim.duration, progress: cutting)

        let clean: URL
        if activeModels.contains(.clear) {
            let enhanced = work.appending(path: "main_clean.wav")
            let cleaning = stage("clear", "Cleaning sanctuary acoustics…")
            try await clear.enhance(
                path: cut.path, to: enhanced.path,
                options: .init(strength: .full, mastering: .bypass, sampleRate: 48_000, channelMode: .mono)
            ) { cleaning($0.fraction) }
            clean = enhanced
        } else {
            clean = cut
        }
        try Task.checkCancellation()

        // 2. Stitch bumpers and master. The intro offset comes back exact.
        let mixing = stage("mix", "Mixing bumpers and mastering to -16 LUFS…")
        let composition = try await AudioCompositionService(ffmpeg: ffmpeg)
            .compose(mainAudio: clean, template: input.template, to: input.output) { mixing($0.fraction) }

        // 3. Who is speaking.
        let diarizationTurns: [SpeakerTurn]
        let speakerCount: Int
        if activeModels.contains(.who) {
            _ = stage("who", "Finding who is speaking…")
            let diarization = try await who.diarize(contentsOf: clean)
                .keepingSpeakers(minimumShare: Self.minimumSpeakerShare)
            diarizationTurns = diarization.turns.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: $0.speaker) }
            speakerCount = diarization.speakerCount
        } else {
            diarizationTurns = []
            speakerCount = 1
        }
        try Task.checkCancellation()

        // 4. Transcript, with the church's own words as hints.
        var words: [TimedWord] = []
        var transcriptText = ""
        if activeModels.contains(.voz) {
            let transcribing = stage("voz", "Writing the transcript…")
            let vocabulary = Self.vocabulary(template: input.template, speakerNames: input.speakerNames)
            let transcript = try await loadedVoz().transcribe(clean, vocabulary: vocabulary) {
                transcribing($0.fractionCompleted)
            }
            words = transcript.words.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            transcriptText = transcript.text
        }

        // 5. Tighten word timings (only if Align is active and transcript exists).
        let needSamples = (activeModels.contains(.align) && !words.isEmpty) || activeModels.contains(.uhm)
        let samples16k = needSamples ? (try await decodeMono16k(clean, in: work)) : []

        if activeModels.contains(.align), !words.isEmpty, !samples16k.isEmpty {
            _ = stage("align", "Lining up every word…")
            let rough = words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
            let refined = (try? await align.isSupported(languageCode: Self.languageCode)) == true
                ? try await align.refine(rough, audio: samples16k, sampleRate: 16_000, languageCode: Self.languageCode)
                : rough
            words = refined.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
        }

        // 6. Fillers and long hesitations.
        var fillers: [FillerMark] = []
        if activeModels.contains(.uhm), !samples16k.isEmpty {
            let finding = stage("uhm", "Counting filler words…")
            let result = try await uhm.analyze(samples: samples16k, sampleRate: 16_000) { finding($0) }
            fillers = result.fillers.map { FillerMark(start: $0.start, end: $0.end, kind: $0.type?.rawValue) }
        }

        // 7. Titles and summary.
        var suggestedTitles: [String] = []
        var summary = ""
        if activeModels.contains(.title), !transcriptText.isEmpty {
            _ = stage("title", "Suggesting titles and a summary…")
            let (titles, desc) = try await suggestTitles(for: transcriptText)
            suggestedTitles = titles
            summary = desc
        }

        onUpdate(.init(message: "Done.", fraction: 1))
        return EpisodeAnalysis.shifted(
            masterURL: composition.outputURL,
            introOffset: composition.introOffsetSeconds,
            mainEnd: composition.plan.mainEnd,
            totalDuration: composition.totalDurationSeconds,
            mainWords: words,
            mainTurns: diarizationTurns,
            speakerCount: speakerCount,
            mainFillers: fillers,
            suggestedTitles: suggestedTitles,
            summary: summary,
            ranModels: activeModels)
    }

    // MARK: - Warm-up

    /// Loads models so Core ML specializes them for this Mac's Neural Engine.
    public func warmUp(
        models: Set<PipelineModel> = Set(PipelineModel.allCases),
        progress: @escaping @Sendable (PipelineModel, Double) -> Void = { _, _ in }
    ) async throws {
        let second = [Float](repeating: 0, count: 16_000)
        if models.contains(.voz) {
            progress(.voz, 0)
            _ = try await loadedVoz()
            progress(.voz, 1)
        }
        if models.contains(.clear) {
            progress(.clear, 0)
            _ = try? await clear.enhance(channels: [[Float](repeating: 0, count: 48_000)], sampleRate: 48_000,
                                         options: .init(mastering: .bypass))
            progress(.clear, 1)
        }
        if models.contains(.who) {
            progress(.who, 0)
            _ = try? await who.diarize(samples: second + second, sampleRate: 16_000)
            progress(.who, 1)
        }
        if models.contains(.uhm) {
            progress(.uhm, 0)
            _ = try? await uhm.analyze(samples: second, sampleRate: 16_000)
            progress(.uhm, 1)
        }
        if models.contains(.align) {
            progress(.align, 1)
        }
        if models.contains(.title), Self.titleRuntimeAvailable {
            progress(.title, 0)
            _ = try await loadedTitles()
            progress(.title, 1)
        }
    }

    // MARK: - Pieces

    private func loadedVoz() async throws -> Voz {
        if let voz { return voz }
        let loaded = try await Voz()
        voz = loaded
        return loaded
    }

    private func loadedTitles() async throws -> Titles {
        if let titles { return titles }
        let loaded = try await Titles(directory: PipelineModel.titleDirectory())
        titles = loaded
        return loaded
    }

    /// Three title ideas (whole message, first half, second half) and a summary
    /// (the whole-message description). Empty when there is nothing to describe.
    private func suggestTitles(for text: String) async throws -> ([String], String) {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(Self.titleWordLimit)
        guard words.count >= 20, Self.titleRuntimeAvailable else { return ([], "") }
        let titles = try await loadedTitles()

        let whole = try await titles.describe(words.joined(separator: " "))
        let half = words.count / 2
        let first = try await titles.describe(words[..<(words.startIndex + half)].joined(separator: " "))
        let second = try await titles.describe(words[(words.startIndex + half)...].joined(separator: " "))

        var seen = Set<String>()
        let options = [whole, first, second]
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return (options, whole.description.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func decodeMono16k(_ url: URL, in work: URL) async throws -> [Float] {
        let raw = work.appending(path: "main_16k.f32")
        try await ffmpeg.run(["-i", url.path, "-ac", "1", "-ar", "16000", "-f", "f32le", "-y", raw.path])
        let data = try Data(contentsOf: raw, options: .alwaysMapped)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Template words plus saved speaker names, without repeats.
    static func vocabulary(template: Template, speakerNames: [String]) -> [String] {
        var seen = Set<String>()
        return (template.vocabularyTerms + speakerNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Title runs on MLX, which needs its compiled GPU library next to the app.
    /// `swift build` does not produce it; `xcodebuild` does. Without it, MLX crashes,
    /// so the pipeline skips titles instead.
    public static var titleRuntimeAvailable: Bool {
        let roots = [Bundle.main.bundleURL, Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0 }
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if url.pathExtension == "metallib" { return true }
                if walker.level > 3 { walker.skipDescendants() }
            }
        }
        return false
    }
}
