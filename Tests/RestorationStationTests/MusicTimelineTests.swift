import Foundation
import Testing
@testable import RestorationStation

@Suite("MusicTimeline Worship Detection")
struct MusicTimelineTests {
    @Test("Speech over a soft instrumental pad stays classified as speech")
    func speechOverPadRule() {
        // Pastor praying over a soft synth/piano pad at the end of a sermon
        let prayerOverPad = MusicTimeline.Window(start: 0, duration: 2, music: 0.50, speech: 0.60)
        #expect(!prayerOverPad.isMusicDominant)

        // Full worship song with singing and instruments
        let worshipSong = MusicTimeline.Window(start: 2, duration: 2, music: 0.85, speech: 0.20)
        #expect(worshipSong.isMusicDominant)

        // Quiet ambient room noise
        let silence = MusicTimeline.Window(start: 4, duration: 2, music: 0.10, speech: 0.05)
        #expect(!silence.isMusicDominant)
    }

    @Test("Bridges inter-song prayers inside a worship set and ignores brief mid-sermon blips")
    func bridgesWorshipSetAndFiltersBlips() {
        var windows: [MusicTimeline.Window] = []

        func appendSpan(from start: Double, to end: Double, music: Float, speech: Float) {
            var t = start
            while t < end {
                windows.append(.init(start: t, duration: 2.0, music: music, speech: speech))
                t += 2.0
            }
        }

        // Song 1: 10s - 250s (4 min)
        appendSpan(from: 10, to: 250, music: 0.88, speech: 0.15)
        // Inter-song welcome & prayer: 250s - 310s (60s gap, <= 90s maxWorshipGap)
        appendSpan(from: 250, to: 310, music: 0.30, speech: 0.75)
        // Song 2: 310s - 600s (~5 min)
        appendSpan(from: 310, to: 600, music: 0.92, speech: 0.10)
        // Sermon part 1: 600s - 1500s
        appendSpan(from: 600, to: 1500, music: 0.05, speech: 0.85)
        // Brief 4-second singing illustration mid-sermon: 1500s - 1504s (< 10s minMusicDuration)
        appendSpan(from: 1500, to: 1504, music: 0.80, speech: 0.10)
        // Sermon part 2: 1504s - 2400s
        appendSpan(from: 1504, to: 2400, music: 0.05, speech: 0.85)
        // Closing prayer over soft pad: 2400s - 2460s
        appendSpan(from: 2400, to: 2460, music: 0.45, speech: 0.65)
        // Closing worship song: 2460s - 2760s (5 min)
        appendSpan(from: 2460, to: 2760, music: 0.90, speech: 0.12)

        let timeline = MusicTimeline(windows: windows)
        #expect(timeline.musicSpans.count == 2)
        #expect(timeline.musicSpans[0] == TrimRange(start: 10, end: 600))
        #expect(timeline.musicSpans[1] == TrimRange(start: 2460, end: 2760))

        let contentTrim = TrimRange(start: 5, end: 2770)
        let sermon = timeline.sermonTrim(within: contentTrim)

        // Sermon starts right after opening worship (600 + headPad) and ends before closing song (2460 - tailPad),
        // keeping the closing prayer over pad (2400 - 2460) inside the message!
        #expect(sermon.start == 600 + LoudnessProfile.headPad)
        #expect(sermon.end == 2460 - LoudnessProfile.tailPad)
    }

    @Test("Preserves contentTrim when no worship is present or recording is pure music")
    func fallbackSafety() {
        let content = TrimRange(start: 12, end: 1800)

        // Pure speech recording
        let emptyTimeline = MusicTimeline(windows: [])
        #expect(emptyTimeline.sermonTrim(within: content) == content)

        // Pure music file covering the whole recording -> falls back to contentTrim rather than zeroing out
        let allMusic = MusicTimeline(musicSpans: [TrimRange(start: 12, end: 1795)])
        #expect(allMusic.sermonTrim(within: content) == content)
    }
}
