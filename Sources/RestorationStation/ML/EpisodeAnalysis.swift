import Foundation

/// A transcribed word. Times are seconds on the master MP3 timeline.
public struct TimedWord: Sendable, Codable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// `Who` speaker number (0, 1, …), or nil when no turn is near the word.
    public var speaker: Int?

    public init(text: String, start: Double, end: Double, speaker: Int? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// One stretch of one speaker talking. Master MP3 time.
public struct SpeakerTurn: Sendable, Codable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// A filler word or long hesitation found by `Uhm`. Master MP3 time.
public struct FillerMark: Sendable, Codable, Equatable {
    public var start: Double
    public var end: Double
    /// "uh", "um", "hmm", "and", "other", or nil.
    public var kind: String?

    public init(start: Double, end: Double, kind: String? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

/// Everything the ML pipeline learned about one episode, already shifted onto the
/// master MP3 timeline (intro bumper included), ready for review and export.
public struct EpisodeAnalysis: Sendable, Codable, Equatable {
    public var masterURL: URL
    /// Master time where the main audio starts (end of the intro bumper).
    public var introOffset: Double
    /// Master time where the main audio ends (start of the outro).
    public var mainEnd: Double
    public var totalDuration: Double

    public var words: [TimedWord]
    public var turns: [SpeakerTurn]
    public var speakerCount: Int
    public var fillers: [FillerMark]
    public var suggestedTitles: [String]
    public var summary: String
    /// Which models ran to produce this analysis.
    public var ranModels: Set<PipelineModel>

    public var transcriptText: String { words.map(\.text).joined(separator: " ") }

    public init(
        masterURL: URL, introOffset: Double, mainEnd: Double, totalDuration: Double,
        words: [TimedWord], turns: [SpeakerTurn], speakerCount: Int, fillers: [FillerMark],
        suggestedTitles: [String], summary: String,
        ranModels: Set<PipelineModel> = Set(PipelineModel.allCases)
    ) {
        self.masterURL = masterURL
        self.introOffset = introOffset
        self.mainEnd = mainEnd
        self.totalDuration = totalDuration
        self.words = words
        self.turns = turns
        self.speakerCount = speakerCount
        self.fillers = fillers
        self.suggestedTitles = suggestedTitles
        self.summary = summary
        self.ranModels = ranModels
    }
}

extension EpisodeAnalysis {
    /// Builds the analysis from results timed on the (trimmed, cleaned) main audio:
    /// adds `introOffset` to every timestamp and tags each word with its speaker.
    static func shifted(
        masterURL: URL, introOffset: Double, mainEnd: Double, totalDuration: Double,
        mainWords: [TimedWord], mainTurns: [SpeakerTurn], speakerCount: Int,
        mainFillers: [FillerMark], suggestedTitles: [String], summary: String,
        ranModels: Set<PipelineModel> = Set(PipelineModel.allCases)
    ) -> EpisodeAnalysis {
        let turns = mainTurns
            .map { SpeakerTurn(start: $0.start + introOffset, end: $0.end + introOffset, speaker: $0.speaker) }
            .sorted { $0.start < $1.start }
        let words = mainWords.map { w in
            var word = TimedWord(text: w.text, start: w.start + introOffset, end: w.end + introOffset)
            word.speaker = speaker(at: (word.start + word.end) / 2, in: turns)
            return word
        }
        let fillers = mainFillers.map {
            FillerMark(start: $0.start + introOffset, end: $0.end + introOffset, kind: $0.kind)
        }
        return EpisodeAnalysis(
            masterURL: masterURL, introOffset: introOffset, mainEnd: mainEnd, totalDuration: totalDuration,
            words: words, turns: turns, speakerCount: speakerCount, fillers: fillers,
            suggestedTitles: suggestedTitles, summary: summary, ranModels: ranModels)
    }

    /// The speaker of the turn containing `time`, else of the nearest turn within 2 s.
    static func speaker(at time: Double, in turns: [SpeakerTurn]) -> Int? {
        if let turn = turns.first(where: { $0.start <= time && time <= $0.end }) { return turn.speaker }
        let nearest = turns.min { distance(time, $0) < distance(time, $1) }
        guard let nearest, distance(time, nearest) <= 2 else { return nil }
        return nearest.speaker
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        time < turn.start ? turn.start - time : max(0, time - turn.end)
    }
}
