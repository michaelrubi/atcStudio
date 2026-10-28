import AVFoundation
import Foundation

public struct CompositionUpdate: Sendable, Equatable {
    public var message: String
    /// Overall progress, 0...1.
    public var fraction: Double

    public init(message: String, fraction: Double) {
        self.message = message
        self.fraction = fraction
    }
}

public struct CompositionResult: Sendable, Equatable {
    public var outputURL: URL
    public var plan: MixPlan
    /// The part of the source file that was kept.
    public var mainTrim: TrimRange
    /// Seconds to add to every transcript and speaker timestamp of the main audio.
    public var introOffsetSeconds: Double { plan.introOffset }
    public var totalDurationSeconds: Double { plan.totalDuration }

    /// Maps a time in the original (untrimmed) main file to the master MP3.
    public func masterTime(forSourceTime t: Double) -> Double {
        plan.introOffset + (t - mainTrim.start)
    }
}

public enum CompositionError: LocalizedError, Equatable {
    case missingFile(label: String, path: String)
    case unreadableAudio(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let label, let path):
            "The \(label) file is missing: \(path). Pick it again in the Templates tab."
        case .unreadableAudio(let name):
            "ATC Studio could not read the audio in \"\(name)\"."
        }
    }
}

/// Stitches the intro and outro bumpers around the main audio, applies the template's
/// ducking envelopes, masters to -16 LUFS (two-pass EBU R128), and writes an MP3.
public struct AudioCompositionService: Sendable {
    public static let loudnessTarget = "I=-16:TP=-1.5:LRA=11"

    public let ffmpeg: FFmpegRunner

    public init(ffmpeg: FFmpegRunner) {
        self.ffmpeg = ffmpeg
    }

    public func compose(
        mainAudio: URL,
        template: Template,
        trim: TrimRange? = nil,
        to output: URL,
        onUpdate: @escaping @Sendable (CompositionUpdate) -> Void = { _ in }
    ) async throws -> CompositionResult {
        onUpdate(.init(message: "Reading your audio…", fraction: 0))

        let introMusic = try stem(template.introMusicPath, label: "Intro Music")
        let introVO = try stem(template.introVoPath, label: "Intro Voice-Over")
        let outroMusic = try stem(template.outroMusicPath, label: "Outro Music")
        let outroVO = try stem(template.outroVoPath, label: "Outro Voice-Over")

        let sourceDuration = try await Self.duration(of: mainAudio)
        let keep = Self.clamp(trim, to: sourceDuration)

        let plan = MixPlan(
            template: template,
            mainDuration: keep.duration,
            hasIntroMusic: introMusic != nil,
            introVODuration: try await introVO.asyncMap(Self.duration(of:)),
            hasOutroMusic: outroMusic != nil,
            outroVODuration: try await outroVO.asyncMap(Self.duration(of:)))

        var inputFiles = [mainAudio]
        var inputs = StemInputs()
        inputs.mainTrim = keep == TrimRange(start: 0, end: sourceDuration) ? nil : keep
        func add(_ url: URL?) -> Int? {
            guard let url else { return nil }
            inputFiles.append(url)
            return inputFiles.count - 1
        }
        inputs.introMusic = add(introMusic)
        inputs.introVO = add(introVO)
        inputs.outroMusic = add(outroMusic)
        inputs.outroVO = add(outroVO)

        let inputArgs = inputFiles.flatMap { ["-i", $0.path] }
        let graph = plan.filterGraph(inputs)

        // Pass 1: measure loudness of the full mix.
        onUpdate(.init(message: "Mixing bumpers and measuring loudness…", fraction: 0.02))
        let measureLog = try await ffmpeg.run(
            inputArgs + [
                "-filter_complex", graph + ";[prog]loudnorm=\(Self.loudnessTarget):print_format=json[out]",
                "-map", "[out]", "-f", "null", "-",
            ],
            duration: plan.totalDuration
        ) { fraction in
            onUpdate(.init(message: "Mixing bumpers and measuring loudness…",
                           fraction: 0.02 + fraction * 0.48))
        }

        // Pass 2: apply the measured correction and encode.
        let loudnorm = Self.secondPassLoudnorm(measured: LoudnessMeasurement(log: measureLog))
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = output.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString)-\(output.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: partial) }

        onUpdate(.init(message: "Mastering to -16 LUFS…", fraction: 0.5))
        try await ffmpeg.run(
            inputArgs + [
                "-filter_complex", graph + ";[prog]\(loudnorm),aresample=\(Int(MixPlan.sampleRate))[out]",
                "-map", "[out]", "-map_metadata", "-1",
                "-c:a", "libmp3lame", "-b:a", "192k", "-ar", "\(Int(MixPlan.sampleRate))",
                "-id3v2_version", "3", "-f", "mp3", "-y", partial.path,
            ],
            duration: plan.totalDuration
        ) { fraction in
            onUpdate(.init(message: "Mastering to -16 LUFS…", fraction: 0.5 + fraction * 0.5))
        }

        _ = try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        onUpdate(.init(message: "Done.", fraction: 1))
        return CompositionResult(outputURL: output, plan: plan, mainTrim: keep)
    }

    public enum Transition: Sendable {
        case intro, outro
    }

    /// Mixes one bumper with a short piece of the message, so a template can be heard
    /// in seconds without making the whole episode. The piece is long enough for the
    /// longest crossfade (5 s) and outro underlap (10 s) the template sliders allow.
    public func preview(
        _ transition: Transition,
        mainAudio: URL,
        template: Template,
        trim: TrimRange? = nil,
        to output: URL
    ) async throws -> CompositionResult {
        let keep = Self.clamp(trim, to: try await Self.duration(of: mainAudio))
        var bumper = template
        let piece: TrimRange
        switch transition {
        case .intro:
            bumper.outroMusicPath = nil
            bumper.outroVoPath = nil
            piece = TrimRange(start: keep.start, end: min(keep.end, keep.start + 12))
        case .outro:
            bumper.introMusicPath = nil
            bumper.introVoPath = nil
            piece = TrimRange(start: max(keep.start, keep.end - 15), end: keep.end)
        }
        return try await compose(mainAudio: mainAudio, template: bumper, trim: piece, to: output)
    }

    /// Keeps the trim inside the file and at least 1 s long; nil means the whole file.
    static func clamp(_ trim: TrimRange?, to duration: Double) -> TrimRange {
        guard let trim else { return TrimRange(start: 0, end: duration) }
        let start = min(max(0, trim.start), max(0, duration - 1))
        let end = min(duration, max(trim.end, start + 1))
        return TrimRange(start: start, end: end)
    }

    private func stem(_ path: String?, label: String) throws -> URL? {
        guard let path, !path.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: path) else {
            throw CompositionError.missingFile(label: label, path: path)
        }
        return URL(filePath: path)
    }

    public static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else {
            throw CompositionError.unreadableAudio(url.lastPathComponent)
        }
        return seconds
    }

    static func secondPassLoudnorm(measured: LoudnessMeasurement?) -> String {
        guard let m = measured else {
            // Silent or unmeasurable input: fall back to one-pass dynamic normalization.
            return "loudnorm=\(loudnessTarget)"
        }
        return "loudnorm=\(loudnessTarget):measured_I=\(m.inputI):measured_TP=\(m.inputTP)"
            + ":measured_LRA=\(m.inputLRA):measured_thresh=\(m.inputThresh):offset=\(m.targetOffset)"
            + ":linear=true:print_format=summary"
    }
}

/// The JSON block `loudnorm=...:print_format=json` prints at the end of ffmpeg's log.
struct LoudnessMeasurement: Equatable {
    var inputI: String
    var inputTP: String
    var inputLRA: String
    var inputThresh: String
    var targetOffset: String

    init?(log: String) {
        guard let open = log.range(of: "{", options: .backwards),
              let close = log.range(of: "}", range: open.upperBound..<log.endIndex),
              let data = String(log[open.lowerBound..<close.upperBound]).data(using: .utf8),
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let i = json["input_i"], let tp = json["input_tp"], let lra = json["input_lra"],
              let thresh = json["input_thresh"], let offset = json["target_offset"]
        else { return nil }
        let values = [i, tp, lra, thresh, offset]
        guard values.allSatisfy({ Double($0)?.isFinite == true }) else { return nil }
        (inputI, inputTP, inputLRA, inputThresh, targetOffset) = (i, tp, lra, thresh, offset)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
