import AVFoundation
import RestorationStation
import SwiftUI

/// Shows where the message starts and ends, and lets a volunteer move either cut,
/// listen to it, or go back to the automatic cut.
struct TrimEditor: View {
    let source: URL
    let profile: LoudnessProfile
    var music: MusicTimeline = MusicTimeline()
    let sourceDuration: Double
    let autoTrim: TrimRange
    var contentTrim: TrimRange?
    @Binding var trim: TrimRange
    @State private var player = PreviewPlayer()

    private static let minLength = 1.0

    private var effectiveContentTrim: TrimRange {
        contentTrim ?? autoTrim
    }

    private var hasDistinctWorshipTrim: Bool {
        music.hasMusic && abs(autoTrim.start - effectiveContentTrim.start) + abs(autoTrim.end - effectiveContentTrim.end) > 1.0
    }

    private enum TrimChoice { case auto, worship, whole, custom }

    private var wholeFile: TrimRange { TrimRange(start: 0, end: sourceDuration) }

    /// Which preset the current cut matches. Moving a cut point by hand makes it Custom.
    private var choice: Binding<TrimChoice> {
        Binding {
            if trim == autoTrim { return .auto }
            if hasDistinctWorshipTrim && trim == effectiveContentTrim { return .worship }
            if trim == wholeFile { return .whole }
            return .custom
        } set: {
            switch $0 {
            case .auto: trim = autoTrim
            case .worship: trim = effectiveContentTrim
            case .whole: trim = wholeFile
            case .custom: break
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Message length: \(Timecode.string(trim.duration))")
                    .font(.headline)
                Text("Removed \(Timecode.short(trim.start)) at the start and \(Timecode.short(sourceDuration - trim.end)) at the end.")
                    .foregroundStyle(.secondary)
                if music.hasMusic {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.purple)
                            .frame(width: 8, height: 8)
                        Text("Worship Music")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
                Spacer()
                Picker("Cut", selection: choice) {
                    if hasDistinctWorshipTrim {
                        Text("Message Only").tag(TrimChoice.auto)
                        Text("Keep Worship").tag(TrimChoice.worship)
                    } else {
                        Text("Auto Cut").tag(TrimChoice.auto)
                    }
                    Text("Whole File").tag(TrimChoice.whole)
                    if choice.wrappedValue == .custom {
                        Text("Custom").tag(TrimChoice.custom)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Message Only cuts the worship music. Keep Worship cuts only the quiet parts.")
            }

            LevelStrip(
                profile: profile,
                musicSpans: music.musicSpans,
                range: 0...max(sourceDuration, 1),
                keep: trim
            )
            .frame(height: 44)

            HStack(alignment: .top, spacing: 16) {
                CutPointEditor(
                    title: "Message starts", edge: .start, profile: profile,
                    musicSpans: music.musicSpans, trim: trim,
                    value: Binding(get: { trim.start }, set: { trim.start = min(max(0, $0), trim.end - Self.minLength) }),
                    onHear: { player.play(source, from: trim.start, for: 5) })
                CutPointEditor(
                    title: "Message ends", edge: .end, profile: profile,
                    musicSpans: music.musicSpans, trim: trim,
                    value: Binding(get: { trim.end }, set: { trim.end = max(min(sourceDuration, $0), trim.start + Self.minLength) }),
                    onHear: { player.play(source, from: max(trim.start, trim.end - 5), until: trim.end) })
            }
        }
        .onDisappear { player.stop() }
    }
}

private struct CutPointEditor: View {
    enum Edge { case start, end }

    let title: String
    let edge: Edge
    let profile: LoudnessProfile
    var musicSpans: [TrimRange] = []
    let trim: TrimRange
    @Binding var value: Double
    let onHear: () -> Void

    /// Seconds shown either side of the cut.
    private static let span = 8.0
    /// The strip's center stays put while dragging, so it doesn't slide under the pointer.
    @State private var dragCenter: Double?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Timecode.string(value, millis: true)).monospacedDigit()
                }

                GeometryReader { geo in
                    let center = dragCenter ?? value
                    let range = (center - Self.span)...(center + Self.span)
                    LevelStrip(profile: profile, musicSpans: musicSpans, range: range, keep: trim, marker: value)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    if dragCenter == nil { dragCenter = value }
                                    let c = dragCenter ?? value
                                    value = c - Self.span + drag.location.x / max(geo.size.width, 1) * Self.span * 2
                                }
                                .onEnded { _ in dragCenter = nil })
                }
                .frame(height: 70)
                .help("Click or drag to move the cut.")

                HStack(spacing: 4) {
                    nudge("-1s", -1)
                    nudge("-0.1s", -0.1)
                    nudge("+0.1s", 0.1)
                    nudge("+1s", 1)
                    Spacer()
                    Button(edge == .start ? "Hear Start" : "Hear End", systemImage: "play.fill", action: onHear)
                }
                .controlSize(.small)
            }
        }
    }

    private func nudge(_ label: String, _ delta: Double) -> some View {
        Button(label) { value += delta }
    }
}

/// Loudness bars for `range` (source seconds). Kept audio is drawn in the accent color,
/// and detected worship/music spans are highlighted in purple.
private struct LevelStrip: View {
    let profile: LoudnessProfile
    var musicSpans: [TrimRange] = []
    let range: ClosedRange<Double>
    let keep: TrimRange
    var marker: Double?

    private static let bottomDb: Float = -70

    var body: some View {
        Canvas { context, size in
            let columns = max(1, Int(size.width / 2))
            let secondsPerColumn = (range.upperBound - range.lowerBound) / Double(columns)
            for column in 0..<columns {
                let t0 = range.lowerBound + Double(column) * secondsPerColumn
                let level = peak(from: t0, to: t0 + secondsPerColumn)
                guard let level else { continue }
                let height = max(1, CGFloat((level - Self.bottomDb) / -Self.bottomDb) * size.height)
                let rect = CGRect(x: CGFloat(column) * 2, y: (size.height - height) / 2, width: 1.5, height: height)
                let tMid = t0 + secondsPerColumn / 2
                let kept = tMid >= keep.start && tMid <= keep.end
                let isMusic = musicSpans.contains { tMid >= $0.start && tMid <= $0.end }
                let barColor: Color = switch (kept, isMusic) {
                case (true, true): .purple
                case (true, false): .accentColor
                case (false, true): .purple.opacity(0.45)
                case (false, false): .secondary.opacity(0.35)
                }
                context.fill(Path(rect), with: .color(barColor))
            }
            for edge in [keep.start, keep.end] + (marker.map { [$0] } ?? []) where range.contains(edge) {
                let x = (edge - range.lowerBound) / (range.upperBound - range.lowerBound) * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    /// Loudest window between `t0` and `t1`, or nil outside the recording.
    private func peak(from t0: Double, to t1: Double) -> Float? {
        let first = max(0, Int(t0 / profile.window))
        let last = min(profile.levels.count, max(first + 1, Int((t1 / profile.window).rounded(.up))))
        guard first < last else { return nil }
        return max(profile.levels[first..<last].max() ?? Self.bottomDb, Self.bottomDb)
    }
}

/// Plays a few seconds of the source so a volunteer can check a cut by ear.
@MainActor @Observable
final class PreviewPlayer {
    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var stopTask: Task<Void, Never>?
    private(set) var isPlaying = false

    func play(_ url: URL, from start: Double, for seconds: Double) {
        play(url, from: start, until: start + seconds)
    }

    func play(_ url: URL, from start: Double, until end: Double) {
        stop()
        if loadedURL != url {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            loadedURL = url
        }
        guard let player else { return }
        player.currentTime = max(0, start)
        player.play()
        isPlaying = true
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, min(end, player.duration) - start)))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        player?.pause()
        isPlaying = false
    }
}

enum Timecode {
    /// `HH:MM:SS`, or `HH:MM:SS.mmm` with `millis`.
    static func string(_ seconds: Double, millis: Bool = false) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let base = String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        return millis ? base + String(format: ".%03d", Int((total - Double(whole)) * 1000)) : base
    }

    /// `4.5 s` or `2 min 10 s`.
    static func short(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return s.formatted(.number.precision(.fractionLength(1))) + " s" }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }
}
