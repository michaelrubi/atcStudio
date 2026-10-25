import Foundation
import Testing
@testable import RestorationStation

@Suite struct EpisodeAnalysisTests {
    @Test func shiftsEveryTimestampByIntroOffset() {
        let a = EpisodeAnalysis.shifted(
            masterURL: URL(filePath: "/x.mp3"), introOffset: 8.5, mainEnd: 68.5, totalDuration: 80,
            mainWords: [TimedWord(text: "Grace", start: 1.0, end: 1.4), TimedWord(text: "Amen", start: 30, end: 30.5)],
            mainTurns: [SpeakerTurn(start: 0.5, end: 20, speaker: 0), SpeakerTurn(start: 25, end: 40, speaker: 1)],
            speakerCount: 2,
            mainFillers: [FillerMark(start: 5, end: 5.3, kind: "um")],
            suggestedTitles: ["Hope"], summary: "About hope.")
        #expect(a.words.map(\.start) == [9.5, 38.5])
        #expect(a.words.map(\.speaker) == [0, 1])
        #expect(a.turns.first?.start == 9.0)
        #expect(a.fillers.first?.start == 13.5)
        #expect(a.transcriptText == "Grace Amen")
    }

    @Test func wordBetweenTurnsTakesNearestWithinTwoSeconds() {
        let turns = [SpeakerTurn(start: 0, end: 10, speaker: 0), SpeakerTurn(start: 13, end: 20, speaker: 1)]
        #expect(EpisodeAnalysis.speaker(at: 12.5, in: turns) == 1)
        #expect(EpisodeAnalysis.speaker(at: 11, in: turns) == 0)
        #expect(EpisodeAnalysis.speaker(at: 30, in: turns) == nil)
    }

    @Test func vocabularyMergesTemplateAndSpeakers() {
        let t = Template(name: "x", customVocabulary: "As The Church, Selah")
        #expect(MLPipelineActor.vocabulary(template: t, speakerNames: ["Pastor John", "selah"])
            == ["As The Church", "Selah", "Pastor John"])
    }
}

private let ffmpeg = try? FFmpegRunner.locate(bundle: Bundle(for: BundleToken.self))
private final class BundleToken {}

/// Downloads and runs all six models (about 0.9 GB the first time). Opt in: ATC_ML_TESTS=1.
@Suite(.enabled(if: ffmpeg != nil && ProcessInfo.processInfo.environment["ATC_ML_TESTS"] == "1"),
       .timeLimit(.minutes(30)))
struct MLPipelineTests {
    @Test func twoVoiceSermonEndToEnd() async throws {
        let runner = ffmpeg!
        for model in PipelineModel.allCases { try await model.download { _ in } }

        let dir = FileManager.default.temporaryDirectory.appending(path: "atc-ml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func say(_ voice: String, _ text: String, _ name: String) throws -> URL {
            let url = dir.appending(path: name)
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/say")
            p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@22050", text]
            try p.run()
            p.waitUntilExit()
            return url
        }
        let pastor = try say("Samantha", """
            Good morning church. Today we are reading from the book of Ecclesiastes, chapter three. \
            To everything there is a season, and a time to every purpose under heaven. \
            Um, I want us to think about what season you are in right now.
            """, "a.wav")
        let guest = try say("Daniel", """
            Thank you pastor. When my family moved here, it felt like a season of waiting. \
            But this church welcomed us, and we found hope again.
            """, "b.wav")
        let raw = dir.appending(path: "sermon.wav")
        try await runner.run([
            "-i", pastor.path, "-i", guest.path, "-filter_complex",
            "[0]aresample=48000,adelay=3000:all=1[a];[1]aresample=48000[b];"
                + "[a][b]concat=n=2:v=0:a=1,apad=pad_dur=4,aformat=channel_layouts=mono",
            "-ar", "48000", "-y", raw.path,
        ])

        let profile = try await LoudnessProfile.measure(raw, ffmpeg: runner)
        let trim = profile.detectContent()
        let music = dir.appending(path: "music.wav")
        try await runner.run(["-f", "lavfi", "-i", "sine=f=220:d=20", "-ar", "48000", "-y", music.path])
        let template = Template(name: "T", introMusicPath: music.path, outroMusicPath: music.path,
                                customVocabulary: "Ecclesiastes")

        let pipeline = MLPipelineActor(ffmpeg: runner)
        let start = Date()
        let analysis = try await pipeline.process(.init(
            source: raw, trim: trim, template: template, speakerNames: ["Pastor John"],
            output: dir.appending(path: "master_episode.mp3")))
        print("ML seconds:", Date().timeIntervalSince(start), "trim:", trim, "offset:", analysis.introOffset)
        print("words:", analysis.words.count, "speakers:", analysis.speakerCount, "fillers:", analysis.fillers.count)
        print("text:", analysis.transcriptText)
        print("turns:", analysis.turns)
        print("first words:", analysis.words.prefix(4))

        #expect(FileManager.default.fileExists(atPath: analysis.masterURL.path))
        #expect(analysis.transcriptText.localizedCaseInsensitiveContains("Ecclesiastes"))
        #expect(analysis.words.count > 50)
        let first = try #require(analysis.words.first)
        // Speech starts 0.5 s into the trimmed clip (the head pad).
        #expect(abs(first.start - (analysis.introOffset + LoudnessProfile.headPad)) < 0.4, "first word \(first.start)")
        #expect(analysis.words.allSatisfy { $0.start >= analysis.introOffset && $0.end <= analysis.mainEnd + 0.5 })
        #expect(analysis.speakerCount == 2)
    }
}
