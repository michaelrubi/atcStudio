import AVFoundation
import Foundation
import SoundAnalysis

/// Music vs. speech timeline for a service recording, used to highlight worship sets
/// on the trim bar and automatically place the default cut points around the sermon.
public struct MusicTimeline: Sendable, Equatable {
    /// One classified time window from `SoundAnalysis`.
    public struct Window: Sendable, Equatable {
        public var start: Double
        public var duration: Double
        /// Confidence (0...1) that this window contains music or singing.
        public var music: Float
        /// Confidence (0...1) that this window contains speech.
        public var speech: Float

        public init(start: Double, duration: Double, music: Float, speech: Float) {
            self.start = start
            self.duration = duration
            self.music = music
            self.speech = speech
        }

        public var end: Double { start + duration }

        /// True when music/singing dominates over spoken word (so a pastor praying
        /// over a soft instrumental pad stays classified as speech).
        public var isMusicDominant: Bool {
            guard music >= MusicTimeline.musicThreshold else { return false }
            if speech >= 0.45 && music < 0.65 { return false }
            return speech < music * MusicTimeline.speechToMusicRatio
        }
    }

    public static let musicThreshold: Float = 0.35
    public static let speechToMusicRatio: Float = 0.75
    /// Minimum sustained music duration (seconds) to count as a song/worship segment.
    public static let minMusicDuration: Double = 10.0
    /// Spoken gaps shorter than this between songs (e.g. inter-song prayer or welcome)
    /// are bridged into a single continuous worship span.
    public static let maxWorshipGap: Double = 90.0

    /// Detected contiguous worship / music sections in source file seconds.
    public var musicSpans: [TrimRange]

    public init(musicSpans: [TrimRange] = []) {
        self.musicSpans = musicSpans
    }

    public var hasMusic: Bool { !musicSpans.isEmpty }

    /// Builds a `MusicTimeline` from raw classifier windows by smoothing transient spikes
    /// and bridging short spoken transitions inside a worship set.
    public init(
        windows: [Window],
        minMusicDuration: Double = MusicTimeline.minMusicDuration,
        maxWorshipGap: Double = MusicTimeline.maxWorshipGap
    ) {
        guard !windows.isEmpty else {
            self.musicSpans = []
            return
        }

        let sorted = windows.sorted { $0.start < $1.start }

        // 1. Collect raw music-dominant intervals, merging adjacent or overlapping windows.
        var rawSpans: [TrimRange] = []
        let mergeTolerance = 2.5
        for w in sorted where w.isMusicDominant {
            if let last = rawSpans.last, w.start <= last.end + mergeTolerance {
                rawSpans[rawSpans.count - 1].end = max(last.end, w.end)
            } else {
                rawSpans.append(TrimRange(start: w.start, end: w.end))
            }
        }

        // 2. Drop brief false-positive blips (e.g. laughter or emphatic vocal inflections)
        // unless they sit right next to another music span.
        let sustained = rawSpans.filter { $0.duration >= minMusicDuration }
        guard !sustained.isEmpty else {
            self.musicSpans = []
            return
        }

        // 3. Bridge short spoken gaps (inter-song prayers/transitions) between sustained songs.
        var bridged: [TrimRange] = [sustained[0]]
        for span in sustained.dropFirst() {
            let last = bridged[bridged.count - 1]
            if span.start - last.end <= maxWorshipGap {
                bridged[bridged.count - 1].end = max(last.end, span.end)
            } else {
                bridged.append(span)
            }
        }

        self.musicSpans = bridged
    }

    /// Computes the sermon-only trim range by stripping opening and closing worship sets
    /// that bookend `contentTrim`. Returns `contentTrim` unchanged if no boundary worship is found
    /// or if stripping music would leave too little audio.
    public func sermonTrim(within contentTrim: TrimRange) -> TrimRange {
        guard contentTrim.duration > 0, !musicSpans.isEmpty else { return contentTrim }

        var start = contentTrim.start
        var end = contentTrim.end
        let edgeTolerance = max(180.0, contentTrim.duration * 0.20)

        // Opening worship: starts near or before the start of content.
        if let first = musicSpans.first,
           first.start <= contentTrim.start + edgeTolerance,
           first.end > start,
           first.end < end
        {
            start = max(start, min(end, first.end + LoudnessProfile.headPad))
        }

        // Closing worship: ends near or after the end of content.
        if let last = musicSpans.last,
           last.end >= contentTrim.end - edgeTolerance,
           last.start < end,
           last.start > start
        {
            end = min(end, max(start, last.start - LoudnessProfile.tailPad))
        }

        let candidate = TrimRange(start: start, end: end)
        let minSermon = min(30.0, contentTrim.duration * 0.25)
        guard candidate.duration >= minSermon else { return contentTrim }
        return candidate
    }

    /// Classifies `url` using Apple's built-in `SoundAnalysis` framework (`SNClassifySoundRequest`).
    /// Never throws on unsupported audio containers; returns an empty timeline if classification fails.
    public static func analyze(
        _ url: URL,
        windowDuration: Double = 1.5,
        overlapFactor: Double = 0.5
    ) async -> MusicTimeline {
        let box = AnalyzerBox()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                do {
                    let analyzer = try SNAudioFileAnalyzer(url: url)
                    box.set(analyzer)
                    if Task.isCancelled {
                        analyzer.cancelAnalysis()
                        return MusicTimeline()
                    }
                    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                    request.windowDuration = CMTime(seconds: windowDuration, preferredTimescale: 600)
                    request.overlapFactor = overlapFactor

                    let observer = SoundObserver()
                    try analyzer.add(request, withObserver: observer)
                    await analyzer.analyze()
                    guard !Task.isCancelled else { return MusicTimeline() }
                    return MusicTimeline(windows: observer.windows)
                } catch {
                    return MusicTimeline()
                }
            }.value
        } onCancel: {
            box.cancel()
        }
    }
}

private final class AnalyzerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: SNAudioFileAnalyzer?

    func set(_ value: SNAudioFileAnalyzer) {
        lock.lock()
        analyzer = value
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let current = analyzer
        lock.unlock()
        current?.cancelAnalysis()
    }
}

private final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [MusicTimeline.Window] = []

    private static let musicLabels: Set<String> = [
        "music", "singing", "choir", "musical_instrument", "acoustic_guitar",
        "electric_guitar", "piano", "keyboard", "drum", "drum_kit", "synthesizer",
        "worship", "gospel_music", "christian_music", "pop_music", "rock_music",
    ]

    private static let speechLabels: Set<String> = [
        "speech", "conversation", "narration", "monologue", "male_speech", "female_speech",
    ]

    var windows: [MusicTimeline.Window] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let start = classification.timeRange.start.seconds
        let duration = classification.timeRange.duration.seconds
        guard start.isFinite, duration.isFinite, duration > 0 else { return }

        var musicConfidence: Float = 0
        var speechConfidence: Float = 0

        for item in classification.classifications {
            let confidence = Float(item.confidence)
            if Self.musicLabels.contains(item.identifier) {
                musicConfidence = max(musicConfidence, confidence)
            } else if Self.speechLabels.contains(item.identifier) {
                speechConfidence = max(speechConfidence, confidence)
            }
        }

        let window = MusicTimeline.Window(
            start: start,
            duration: duration,
            music: musicConfidence,
            speech: speechConfidence
        )
        lock.lock()
        collected.append(window)
        lock.unlock()
    }
}
