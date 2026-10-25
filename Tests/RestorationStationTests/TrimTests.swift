import Foundation
import Testing
@testable import RestorationStation

@Suite struct TrimDetectionTests {
    /// `quiet` seconds of room noise, `loud` seconds of speech-level sound, `tail` seconds of noise.
    private func profile(quiet: Double, loud: Double, tail: Double, noise: Float = -60, speech: Float = -20) -> LoudnessProfile {
        let w = 0.05
        let levels = Array(repeating: noise, count: Int(quiet / w))
            + Array(repeating: speech, count: Int(loud / w))
            + Array(repeating: noise, count: Int(tail / w))
        return LoudnessProfile(window: w, levels: levels)
    }

    @Test func trimsRoomNoiseBothEnds() {
        let range = profile(quiet: 4, loud: 60, tail: 30).detectContent()
        #expect(abs(range.start - 3.5) < 0.06) // 4 s minus 0.5 s pad
        #expect(abs(range.end - 65) < 0.06)    // 64 s plus 1 s pad
    }

    @Test func ignoresASingleClick() {
        var p = profile(quiet: 4, loud: 60, tail: 30)
        var levels = p.levels
        levels[20] = -10 // 1 s in: a bump
        levels[levels.count - 40] = -10 // 2 s before the end
        p = LoudnessProfile(window: p.window, levels: levels)
        let range = p.detectContent()
        #expect(abs(range.start - 3.5) < 0.06)
        #expect(abs(range.end - 65) < 0.06)
    }

    @Test func keepsWholeFileWhenNoContrast() {
        let p = profile(quiet: 5, loud: 5, tail: 5, noise: -30, speech: -25)
        #expect(p.detectContent() == TrimRange(start: 0, end: p.duration))
    }

    @Test func clampsTrimInsideFile() {
        #expect(AudioCompositionService.clamp(TrimRange(start: -2, end: 99), to: 10) == TrimRange(start: 0, end: 10))
        #expect(AudioCompositionService.clamp(TrimRange(start: 9.8, end: 9.9), to: 10) == TrimRange(start: 9, end: 10))
        #expect(AudioCompositionService.clamp(nil, to: 10) == TrimRange(start: 0, end: 10))
    }
}

private let ffmpeg = try? FFmpegRunner.locate(bundle: Bundle(for: BundleToken.self))
private final class BundleToken {}

@Suite(.enabled(if: ffmpeg != nil, "ffmpeg not installed"))
struct TrimAudioTests {
    let runner = ffmpeg!

    @Test func measuresAndTrimsRealAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "atc-trim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 3 s of quiet hiss, 5 s of tone over the hiss, then 6 s of quiet hiss.
        let source = dir.appending(path: "sermon.wav")
        try await runner.run([
            "-f", "lavfi", "-i", "anoisesrc=d=14:c=pink:a=0.002",
            "-f", "lavfi", "-i", "sine=f=300:d=5",
            "-filter_complex", "[1]volume=0.3,adelay=3000:all=1,apad=whole_dur=14[t];[0][t]amix=inputs=2:normalize=0",
            "-ac", "1", "-ar", "48000", "-y", source.path,
        ])

        let profile = try await LoudnessProfile.measure(source, ffmpeg: runner)
        #expect(abs(profile.duration - 14) < 0.1)
        let auto = profile.detectContent()
        #expect(abs(auto.start - 2.5) < 0.1, "start \(auto.start)")
        #expect(abs(auto.end - 9.0) < 0.1, "end \(auto.end)")

        let output = dir.appending(path: "out.mp3")
        let result = try await AudioCompositionService(ffmpeg: runner)
            .compose(mainAudio: source, template: Template(name: "Plain"), trim: auto, to: output)
        let duration = try await AudioCompositionService.duration(of: output)
        #expect(abs(duration - auto.duration) < 0.1, "duration \(duration)")
        #expect(result.masterTime(forSourceTime: auto.start) == 0)
    }
}
