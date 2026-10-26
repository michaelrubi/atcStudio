import Foundation
import Testing
@testable import RestorationStation

@Suite struct EpisodePackageTests {
    private static func analysis() -> EpisodeAnalysis {
        EpisodeAnalysis(
            masterURL: URL(filePath: "/x.mp3"), introOffset: 8.5, mainEnd: 68.5, totalDuration: 80,
            words: [
                TimedWord(text: "Good", start: 9.0, end: 9.3, speaker: 0),
                TimedWord(text: "morning.", start: 9.3, end: 9.8, speaker: 0),
                TimedWord(text: "Rock", start: 30.0, end: 30.4, speaker: 1),
                TimedWord(text: "&", start: 30.4, end: 30.5, speaker: 1),
                TimedWord(text: "<roll>", start: 30.5, end: 31.0, speaker: 1),
            ],
            turns: [SpeakerTurn(start: 9, end: 29, speaker: 0), SpeakerTurn(start: 30, end: 33, speaker: 1)],
            speakerCount: 2,
            fillers: [FillerMark(start: 12, end: 12.4, kind: "um")],
            suggestedTitles: ["**Hope** Rising", "Grace"],
            summary: "A message about # hope.")
    }

    private static func package() -> EpisodePackage {
        var p = EpisodePackage(analysis: analysis(), fallbackTitle: "file", date: Date(timeIntervalSince1970: 1_790_000_000))
        p.speakerNames = [0: "Pastor John"]
        return p
    }

    @Test func webVTTHasVoiceTagsEscapingAndMasterTimes() {
        let vtt = Self.package().webVTT
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        #expect(vtt.contains("00:00:09.000 --> 00:00:09.800\n<v Pastor John>Good morning.\n"))
        #expect(vtt.contains("00:00:30.000 --> 00:00:31.000\n<v Speaker 2>Rock &amp; &lt;roll&gt;\n"))
    }

    @Test func cuesBreakOnPauseAndLength() {
        let words = (0..<40).map { TimedWord(text: "w", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25, speaker: 0) }
            + [TimedWord(text: "late", start: 30, end: 30.5, speaker: 0)]
        let cues = EpisodePackage.cues(from: words)
        #expect(cues.allSatisfy { $0.words.count <= EpisodePackage.cueMaxWords })
        #expect(cues.last?.words.map(\.text) == ["late"])
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func episodeInfoIsPlainTextInSpecOrder() {
        let info = Self.package().episodeInfo
        for mark in ["#", "*", "`"] { #expect(!info.contains(mark)) }
        let order = ["SUGGESTED TITLES:\n1. Hope Rising\n2. Grace", "SPEAKERS:\nPastor John, Speaker 2", "DATE:",
                     "EPISODE SUMMARY:\nA message about  hope.",
                     "TIMESTAMPS:\n00:00:00 - Intro\n00:00:08 - Main Message\n00:01:08 - Outro",
                     "FILLER WORD REPORT (Uhm):\nDetected 1 filler words / long hesitations.",
                     "FULL TRANSCRIPT:\nPastor John: Good morning.\n\nSpeaker 2: Rock & <roll>"]
        let positions = order.map { info.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
    }

    @Test func mp3OnlyPackageSkipsTranscriptSections() {
        let p = EpisodePackage(title: "Sunday", introOffset: 0, mainEnd: 60, totalDuration: 60)
        #expect(!p.episodeInfo.contains("SPEAKERS:"))
        #expect(!p.episodeInfo.contains("FULL TRANSCRIPT:"))
        #expect(p.timestampLines == ["00:00:00 - Main Message"])
        #expect(p.showNotes == "Sunday\n\n00:00:00 - Main Message")
    }

    @Test func speakersSortedByTalkTimeWithSampleInsideLongestTurn() {
        let speakers = Self.analysis().speakers
        #expect(speakers.map(\.speaker) == [0, 1])
        #expect(speakers[0].sample == 16...22)
        #expect(speakers[1].sample == 30...33)
    }

    @Test func sameNameTwiceIsListedOnce() {
        var p = Self.package()
        p.speakerNames = [0: "Pastor John", 1: "pastor john"]
        #expect(p.speakerList == ["Pastor John"])
    }

    @Test func exportWritesFilesAndRenamesFolderToTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ATCExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Self.package()
        let first = ExportLocation.newFolder(title: "raw recording", date: p.date, root: root)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try Data("mp3".utf8).write(to: first.appending(path: EpisodePackageExporter.masterName))

        let art = root.appending(path: "art.png")
        try Self.onePixelPNG.write(to: art)
        let folder = try EpisodePackageExporter.export(p, artworkPath: art.path, in: first)

        #expect(folder.lastPathComponent.hasSuffix("_Hope_Rising"))
        for name in [EpisodePackageExporter.masterName, EpisodePackageExporter.transcriptName,
                     EpisodePackageExporter.infoName, EpisodePackageExporter.artworkName] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path), "\(name)")
        }
        let jpeg = try Data(contentsOf: folder.appending(path: EpisodePackageExporter.artworkName))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))

        // Saving again with the same title keeps the folder.
        #expect(try EpisodePackageExporter.export(p, artworkPath: nil, in: folder) == folder)
    }

    @Test func folderNameMatching() {
        let date = Date()
        let base = ExportLocation.newFolder(title: "Hope", date: date, root: URL(filePath: "/nowhere"))
        #expect(ExportLocation.folder(base, isNamedFor: "Hope", date: date))
        #expect(ExportLocation.folder(URL(filePath: base.path + "_3"), isNamedFor: "Hope", date: date))
        #expect(!ExportLocation.folder(URL(filePath: base.path + "_Rising"), isNamedFor: "Hope", date: date))
    }

    @Test func partialModelPackageSkipsUnrunSections() throws {
        let analysis = EpisodeAnalysis(
            masterURL: URL(filePath: "/x.mp3"), introOffset: 0, mainEnd: 60, totalDuration: 60,
            words: [], turns: [], speakerCount: 1, fillers: [], suggestedTitles: [], summary: "",
            ranModels: [.clear])
        let p = EpisodePackage(analysis: analysis, fallbackTitle: "Sunday Service")
        #expect(!p.episodeInfo.contains("SPEAKERS:"))
        #expect(!p.episodeInfo.contains("FILLER WORD REPORT"))
        #expect(!p.episodeInfo.contains("FULL TRANSCRIPT:"))

        let root = FileManager.default.temporaryDirectory.appending(path: "ATCExportPartial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("mp3".utf8).write(to: root.appending(path: EpisodePackageExporter.masterName))

        let exported = try EpisodePackageExporter.export(p, artworkPath: nil, in: root)
        #expect(!FileManager.default.fileExists(atPath: exported.appending(path: EpisodePackageExporter.transcriptName).path))
        #expect(FileManager.default.fileExists(atPath: exported.appending(path: EpisodePackageExporter.infoName).path))
    }

    @Test func pipelineModelNormalization() {
        #expect(PipelineModel.normalized([.align, .title]) == [])
        #expect(PipelineModel.normalized([.align, .title, .voz]) == [.align, .title, .voz])
        #expect(PipelineModel.normalized([.clear, .who]) == [.clear, .who])
        #expect(PipelineModel.normalized([.voz, .clear]) == [.voz, .clear])
    }

    @Test func tagMasterWritesID3AndSkipsUnchangedRewrite() throws {
        guard let ffmpeg = try? FFmpegRunner.locate(),
              let ffprobe = try? FFmpegRunner.locate(tool: "ffprobe") else { return }

        let root = FileManager.default.temporaryDirectory.appending(path: "ATCID3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var p = Self.package()
        let initialFolder = ExportLocation.newFolder(title: "raw", date: p.date, root: root)
        try FileManager.default.createDirectory(at: initialFolder, withIntermediateDirectories: true)

        let rawMP3 = initialFolder.appending(path: EpisodePackageExporter.masterName)
        try ffmpeg.runSync([
            "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=440:d=0.3",
            "-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3", "-y", rawMP3.path,
        ])

        let art = root.appending(path: "art.png")
        try Self.onePixelPNG.write(to: art)

        let folder = try EpisodePackageExporter.export(p, artworkPath: art.path, in: initialFolder)
        let masterURL = folder.appending(path: EpisodePackageExporter.masterName)

        let probeJSON = try ffprobe.runSync([
            "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", masterURL.path,
        ])
        let probeData = Data(probeJSON.utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: probeData) as? [String: Any])
        let format = try #require(parsed["format"] as? [String: Any])
        let tags = try #require(format["tags"] as? [String: String])
        #expect(tags["title"] == "**Hope** Rising")
        #expect(tags["artist"] == "Pastor John, Speaker 2")
        #expect(tags["comment"] == "A message about # hope.")
        #expect(tags["date"] == ExportLocation.dateString(p.date))

        let streams = try #require(parsed["streams"] as? [[String: Any]])
        let hasAttachedPic = streams.contains { stream in
            (stream["codec_name"] as? String) == "mjpeg"
                && ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
        }
        #expect(hasAttachedPic)

        // Set a known modification date in the past, then save again with no changes: must not rewrite.
        let pastDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: masterURL.path)
        let secondFolder = try EpisodePackageExporter.export(p, artworkPath: nil, in: folder)
        #expect(secondFolder == folder)
        let modAfterUnchanged = try FileManager.default.attributesOfItem(atPath: masterURL.path)[.modificationDate] as? Date
        #expect(modAfterUnchanged == pastDate)

        // Changing a speaker name re-tags the file and updates its modification date.
        p.speakerNames[1] = "Pastor Sarah"
        _ = try EpisodePackageExporter.export(p, artworkPath: nil, in: folder)
        let modAfterEdit = try FileManager.default.attributesOfItem(atPath: masterURL.path)[.modificationDate] as? Date
        #expect(modAfterEdit != pastDate)

        let updatedProbe = try ffprobe.runSync([
            "-v", "quiet", "-print_format", "json", "-show_format", masterURL.path,
        ])
        let updatedFormat = try #require(
            (try JSONSerialization.jsonObject(with: Data(updatedProbe.utf8)) as? [String: Any])?["format"] as? [String: Any]
        )
        let updatedTags = try #require(updatedFormat["tags"] as? [String: String])
        #expect(updatedTags["artist"] == "Pastor John, Pastor Sarah")
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
}
