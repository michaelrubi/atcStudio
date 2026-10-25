import Foundation

/// What the volunteer settled on in the review view, plus the run's timing.
/// Turns into the text of `transcript.vtt`, `episode_info.txt`, and the show notes.
public struct EpisodePackage: Sendable, Equatable {
    public var title: String
    public var suggestedTitles: [String]
    public var summary: String
    /// Name for each `Who` speaker number. Missing or blank → "Speaker N".
    public var speakerNames: [Int: String]
    public var date: Date
    public var introOffset: Double
    public var mainEnd: Double
    public var totalDuration: Double
    /// Nil when only the MP3 was made (no models): no transcript, speakers, or fillers.
    public var analysis: EpisodeAnalysis?

    public init(
        title: String, suggestedTitles: [String] = [], summary: String = "", speakerNames: [Int: String] = [:],
        date: Date = Date(), introOffset: Double, mainEnd: Double, totalDuration: Double,
        analysis: EpisodeAnalysis? = nil
    ) {
        self.title = title
        self.suggestedTitles = suggestedTitles
        self.summary = summary
        self.speakerNames = speakerNames
        self.date = date
        self.introOffset = introOffset
        self.mainEnd = mainEnd
        self.totalDuration = totalDuration
        self.analysis = analysis
    }

    /// A first package straight from the pipeline: first title idea, model summary, no names yet.
    public init(analysis: EpisodeAnalysis, fallbackTitle: String, date: Date = Date()) {
        self.init(
            title: analysis.suggestedTitles.first ?? fallbackTitle, suggestedTitles: analysis.suggestedTitles,
            summary: analysis.summary, date: date, introOffset: analysis.introOffset, mainEnd: analysis.mainEnd,
            totalDuration: analysis.totalDuration, analysis: analysis)
    }

    public static func defaultName(for speaker: Int) -> String { "Speaker \(speaker + 1)" }

    public func name(for speaker: Int) -> String {
        let typed = speakerNames[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? Self.defaultName(for: speaker) : typed
    }

    /// Mapped names, most talk time first, without repeats (two voices can be one person).
    public var speakerList: [String] {
        var seen = Set<String>()
        return (analysis?.speakers ?? []).map { name(for: $0.speaker) }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - transcript.vtt

    /// Valid WebVTT: one cue per short phrase, `<v Name>` voice tags, master MP3 times.
    public var webVTT: String {
        var out = "WEBVTT\n"
        for cue in Self.cues(from: analysis?.words ?? []) {
            let text = Self.escapeVTT(cue.words.map(\.text).joined(separator: " "))
            let voice = cue.speaker.map { "<v \(Self.escapeVTT(name(for: $0)))>" } ?? ""
            out += "\n\(Self.vttTime(cue.start)) --> \(Self.vttTime(cue.end))\n\(voice)\(text)\n"
        }
        return out
    }

    struct Cue: Equatable {
        var speaker: Int?
        var words: [TimedWord]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { max(words.last?.end ?? 0, start + 0.001) }
    }

    static let cueMaxSeconds = 7.0
    static let cueMaxWords = 16
    static let cueBreakGap = 1.5

    /// Breaks on a new speaker, a pause, a long cue, or a sentence end once the cue is 2 s long.
    static func cues(from words: [TimedWord]) -> [Cue] {
        var cues: [Cue] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if var last = cues.last, let previous = last.words.last {
                let sentenceEnded = previous.text.last.map { ".?!".contains($0) } ?? false
                let breaks = word.speaker != last.speaker
                    || word.start - previous.end > cueBreakGap
                    || word.end - last.start > cueMaxSeconds
                    || last.words.count >= cueMaxWords
                    || (sentenceEnded && previous.end - last.start >= 2)
                if !breaks {
                    last.words.append(word)
                    cues[cues.count - 1] = last
                    continue
                }
            }
            cues.append(Cue(speaker: word.speaker, words: [word]))
        }
        // A cue never runs past the start of the next one.
        for i in cues.indices.dropLast() where cues[i].words.last!.end > cues[i + 1].start {
            cues[i].words[cues[i].words.count - 1].end = cues[i + 1].start
        }
        return cues
    }

    static func vttTime(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - episode_info.txt

    /// Plain text for Podbean: no `#`, `*`, or backticks anywhere.
    public var episodeInfo: String {
        var sections: [String] = []
        let titles = titleOptions.enumerated().map { "\($0.offset + 1). \($0.element)" }
        sections.append("SUGGESTED TITLES:\n" + titles.joined(separator: "\n"))
        if analysis != nil {
            sections.append("SPEAKERS:\n" + speakerList.joined(separator: ", "))
        }
        sections.append("DATE:\n" + date.formatted(date: .complete, time: .omitted))
        if !summary.isBlank {
            sections.append("EPISODE SUMMARY:\n" + summary.trimmed)
        }
        sections.append("TIMESTAMPS:\n" + timestampLines.joined(separator: "\n"))
        if let analysis {
            sections.append("FILLER WORD REPORT (Uhm):\nDetected \(analysis.fillers.count) filler words / long hesitations.")
            sections.append("FULL TRANSCRIPT:\n" + transcriptParagraphs.joined(separator: "\n\n"))
        }
        return Self.plain(sections.joined(separator: "\n\n")) + "\n"
    }

    /// The chosen title first, then the other ideas, at most 3.
    public var titleOptions: [String] {
        var seen = Set<String>()
        return ([title] + suggestedTitles)
            .map(\.trimmed)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    public var timestampLines: [String] {
        var lines: [String] = []
        if introOffset > 0.5 { lines.append("00:00:00 - Intro") }
        lines.append("\(Self.clock(introOffset > 0.5 ? introOffset : 0)) - Main Message")
        if totalDuration - mainEnd > 0.5 { lines.append("\(Self.clock(mainEnd)) - Outro") }
        return lines
    }

    /// "Name: words…", one paragraph per stretch of one speaker.
    var transcriptParagraphs: [String] {
        var paragraphs: [(speaker: Int?, words: [String])] = []
        for word in (analysis?.words ?? []).sorted(by: { $0.start < $1.start }) {
            if let last = paragraphs.last, last.speaker == word.speaker || word.speaker == nil {
                paragraphs[paragraphs.count - 1].words.append(word.text)
            } else {
                paragraphs.append((word.speaker, [word.text]))
            }
        }
        return paragraphs.map { p in
            let text = p.words.joined(separator: " ")
            return p.speaker.map { "\(name(for: $0)): \(text)" } ?? text
        }
    }

    // MARK: - Show notes

    /// What "Copy Show Notes" puts on the clipboard: title, summary, speakers, timestamps.
    public var showNotes: String {
        var parts = [title.trimmed]
        if !summary.isBlank { parts.append(summary.trimmed) }
        if !speakerList.isEmpty { parts.append("Speakers: " + speakerList.joined(separator: ", ")) }
        parts.append(timestampLines.joined(separator: "\n"))
        return Self.plain(parts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    // MARK: - Helpers

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// Drops the Markdown marks the Title model sometimes writes (`#`, `*`, backticks).
    static func plain(_ text: String) -> String {
        text.filter { !"#*`".contains($0) }
    }
}

extension EpisodeAnalysis {
    public struct SpeakerInfo: Sendable, Equatable, Identifiable {
        public var speaker: Int
        public var talkTime: Double
        /// Share of all talk time, 0...1.
        public var share: Double
        /// Master MP3 times of a clear stretch of this voice, up to `sampleLength` long.
        public var sample: ClosedRange<Double>
        public var id: Int { speaker }
    }

    public static let sampleLength = 6.0

    /// Every speaker with at least one turn, most talk time first.
    /// The sample is the middle of the speaker's longest turn: away from the hand-over edges.
    public var speakers: [SpeakerInfo] {
        let total = turns.reduce(0) { $0 + ($1.end - $1.start) }
        return Dictionary(grouping: turns, by: \.speaker)
            .map { speaker, turns in
                let talk = turns.reduce(0) { $0 + ($1.end - $1.start) }
                let longest = turns.max { ($0.end - $0.start) < ($1.end - $1.start) }!
                let length = min(Self.sampleLength, longest.end - longest.start)
                let start = longest.start + ((longest.end - longest.start) - length) / 2
                return SpeakerInfo(speaker: speaker, talkTime: talk, share: total > 0 ? talk / total : 0,
                                   sample: start...(start + length))
            }
            .sorted { $0.talkTime != $1.talkTime ? $0.talkTime > $1.talkTime : $0.speaker < $1.speaker }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}
