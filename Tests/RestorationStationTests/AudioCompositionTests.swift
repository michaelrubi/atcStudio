import Foundation
import Testing
@testable import RestorationStation

private let ffmpeg = try? FFmpegRunner.locate(bundle: Bundle(for: BundleToken.self))
private final class BundleToken {}

/// End-to-end mixes with real ffmpeg on generated tones. Skipped when ffmpeg is not installed.
@Suite(.enabled(if: ffmpeg != nil, "ffmpeg not installed"), .serialized)
struct AudioCompositionTests {
    let runner = ffmpeg!
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "atc-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Writes a WAV from an ffmpeg lavfi source.
    private func tone(_ name: String, _ source: String, mono: Bool = false) async throws -> URL {
        let url = dir.appending(path: name)
        try await runner.run(["-f", "lavfi", "-i", source, "-ac", mono ? "1" : "2", "-ar", "48000", "-y", url.path])
        return url
    }

    /// Master times where the 1 kHz band switches on (end of each silence).
    /// Band-pass, so clicks from the test tones' hard edges don't count.
    private func highBandOnsets(_ url: URL) async throws -> [Double] {
        let log = try await runner.run([
            "-i", url.path,
            "-af", "bandpass=f=1000:width_type=q:w=4,bandpass=f=1000:width_type=q:w=4,highpass=f=800,highpass=f=800,"
                + "silencedetect=n=-40dB:d=0.3",
            "-f", "null", "-",
        ])
        return log.split(separator: "\n").compactMap { line in
            guard let r = line.range(of: "silence_end: ") else { return nil }
            return Double(line[r.upperBound...].prefix { !$0.isWhitespace && $0 != "|" })
        }
    }

    @Test func mainAudioLandsAtIntroOffset() async throws {
        // Low tones for bumpers (removed by the high-pass), a 1 kHz burst 3 s into the main audio.
        let introMusic = try await tone("intro_music.wav", "sine=f=220:d=30")
        let introVO = try await tone("intro_vo.wav", "sine=f=330:d=4", mono: true)
        let outroMusic = try await tone("outro_music.wav", "sine=f=220:d=30")
        let outroVO = try await tone("outro_vo.wav", "sine=f=330:d=4")
        let main = dir.appending(path: "sermon.wav")
        try await runner.run([
            "-f", "lavfi", "-i", "sine=f=1000:d=1",
            "-af", "adelay=3000:all=1,apad=whole_dur=10,volume=0.5", "-ac", "1", "-ar", "48000", "-y", main.path,
        ])

        var template = Template(name: "Test")
        template.introMusicPath = introMusic.path
        template.introVoPath = introVO.path
        template.outroMusicPath = outroMusic.path
        template.outroVoPath = outroVO.path

        let output = dir.appending(path: "out/master_episode.mp3")
        let updates = UpdateLog()
        let result = try await AudioCompositionService(ffmpeg: runner)
            .compose(mainAudio: main, template: template, to: output) { updates.append($0) }

        #expect(abs(result.introOffsetSeconds - 8.5) < 0.001) // 3 lead-in + 4 VO + 1.5 swell
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(updates.last?.fraction == 1)

        let onsets = try await highBandOnsets(output)
        let burst = try #require(onsets.first)
        #expect(abs(burst - (result.introOffsetSeconds + 3)) < 0.02, "burst at \(burst)")

        let duration = try await AudioCompositionService.duration(of: output)
        #expect(abs(duration - result.totalDurationSeconds) < 0.1, "duration \(duration)")

        let loudness = try #require(LoudnessMeasurement(log: try await runner.run([
            "-i", output.path, "-af", "loudnorm=print_format=json", "-f", "null", "-",
        ])))
        #expect(abs(try #require(Double(loudness.inputI)) + 16) < 1.0, "integrated \(loudness.inputI) LUFS")
    }

    @Test func noBumpersStillMasters() async throws {
        let main = try await tone("plain.wav", "sine=f=500:d=5", mono: true)
        let output = dir.appending(path: "plain.mp3")
        let result = try await AudioCompositionService(ffmpeg: runner)
            .compose(mainAudio: main, template: Template(name: "Empty"), to: output)
        #expect(result.introOffsetSeconds == 0)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func missingStemIsReported() async throws {
        let main = try await tone("m.wav", "sine=f=500:d=2")
        let template = Template(name: "Broken", introMusicPath: "/nope/intro.wav")
        await #expect(throws: CompositionError.missingFile(label: "Intro Music", path: "/nope/intro.wav")) {
            try await AudioCompositionService(ffmpeg: runner)
                .compose(mainAudio: main, template: template, to: dir.appending(path: "x.mp3"))
        }
    }

    @Test func cancellingStopsFFmpeg() async throws {
        let task = Task {
            try await runner.run(["-f", "lavfi", "-i", "sine=f=440:d=3600", "-f", "null", "-"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CompositionUpdate] = []
    func append(_ u: CompositionUpdate) { lock.withLock { items.append(u) } }
    var last: CompositionUpdate? { lock.withLock { items.last } }
}
