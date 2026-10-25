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

        public init(source: URL, trim: TrimRange, template: Template, speakerNames: [String], output: URL) {
            self.source = source
            self.trim = trim
            self.template = template
            self.speakerNames = speakerNames
            self.output = output
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

        func stage(_ message: String, _ range: ClosedRange<Double>) -> @Sendable (Double) -> Void {
            onUpdate(.init(message: "Restoration Station: \(message)", fraction: range.lowerBound))
            return { f in
                onUpdate(.init(message: "Restoration Station: \(message)",
                               fraction: range.lowerBound + min(1, max(0, f)) * (range.upperBound - range.lowerBound)))
            }
        }

        // 1. Cut the kept part, then clean it. Everything after this is timed on `clean`.
        let cut = work.appending(path: "main_cut.wav")
        let cutting = stage("Trimming the message…", 0...0.02)
        try await ffmpeg.run([
            "-i", input.source.path, "-map", "0:a:0",
            "-af", "atrim=start=\(seconds(input.trim.start)):end=\(seconds(input.trim.end)),asetpts=PTS-STARTPTS",
            "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", "-y", cut.path,
        ], duration: input.trim.duration, progress: cutting)

        let clean = work.appending(path: "main_clean.wav")
        let cleaning = stage("Cleaning sanctuary acoustics…", 0.02...0.25)
        try await clear.enhance(
            path: cut.path, to: clean.path,
            options: .init(strength: .full, mastering: .bypass, sampleRate: 48_000, channelMode: .mono)
        ) { cleaning($0.fraction) }
        try Task.checkCancellation()

        // 2. Stitch bumpers and master. The intro offset comes back exact.
        let mixing = stage("Mixing bumpers and mastering to -16 LUFS…", 0.25...0.45)
        let composition = try await AudioCompositionService(ffmpeg: ffmpeg)
            .compose(mainAudio: clean, template: input.template, to: input.output) { mixing($0.fraction) }

        // 3. Who is speaking.
        _ = stage("Finding who is speaking…", 0.45...0.55)
        let diarization = try await who.diarize(contentsOf: clean)
            .keepingSpeakers(minimumShare: Self.minimumSpeakerShare)
        try Task.checkCancellation()

        // 4. Transcript, with the church's own words as hints.
        let transcribing = stage("Writing the transcript…", 0.55...0.8)
        let vocabulary = Self.vocabulary(template: input.template, speakerNames: input.speakerNames)
        let transcript = try await loadedVoz().transcribe(clean, vocabulary: vocabulary) {
            transcribing($0.fractionCompleted)
        }

        // 5. Tighten word timings.
        _ = stage("Lining up every word…", 0.8...0.85)
        let samples16k = try await decodeMono16k(clean, in: work)
        let rough = transcript.words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end) }
        let refined = (try? await align.isSupported(languageCode: Self.languageCode)) == true && !samples16k.isEmpty
            ? try await align.refine(rough, audio: samples16k, sampleRate: 16_000, languageCode: Self.languageCode)
            : rough

        // 6. Fillers and long hesitations.
        let finding = stage("Counting filler words…", 0.85...0.92)
        let fillers = try await uhm.analyze(samples: samples16k, sampleRate: 16_000) { finding($0) }

        // 7. Titles and summary.
        _ = stage("Suggesting titles and a summary…", 0.92...0.99)
        let (suggestedTitles, summary) = try await suggestTitles(for: transcript.text)

        onUpdate(.init(message: "Restoration Station: Done.", fraction: 1))
        return EpisodeAnalysis.shifted(
            masterURL: composition.outputURL,
            introOffset: composition.introOffsetSeconds,
            mainEnd: composition.plan.mainEnd,
            totalDuration: composition.totalDurationSeconds,
            mainWords: refined.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) },
            mainTurns: diarization.turns.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: $0.speaker) },
            speakerCount: diarization.speakerCount,
            mainFillers: fillers.fillers.map { FillerMark(start: $0.start, end: $0.end, kind: $0.type?.rawValue) },
            suggestedTitles: suggestedTitles,
            summary: summary)
    }

    // MARK: - Warm-up

    /// Loads every model once so Core ML specializes it for this Mac's Neural Engine
    /// now, not during the first real episode (about 20 s for Voz alone).
    public func warmUp(progress: @escaping @Sendable (PipelineModel, Double) -> Void = { _, _ in }) async throws {
        let second = [Float](repeating: 0, count: 16_000)
        progress(.voz, 0)
        _ = try await loadedVoz()
        progress(.voz, 1)
        progress(.clear, 0)
        _ = try? await clear.enhance(channels: [[Float](repeating: 0, count: 48_000)], sampleRate: 48_000,
                                     options: .init(mastering: .bypass))
        progress(.clear, 1)
        progress(.who, 0)
        _ = try? await who.diarize(samples: second + second, sampleRate: 16_000)
        progress(.who, 1)
        progress(.uhm, 0)
        _ = try? await uhm.analyze(samples: second, sampleRate: 16_000)
        progress(.uhm, 1)
        progress(.align, 1)
        if Self.titleRuntimeAvailable {
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
