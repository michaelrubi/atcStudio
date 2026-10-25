import Foundation

/// Short-window RMS levels of a recording, used to find where the message
/// starts and ends and to draw the trim editor.
public struct LoudnessProfile: Sendable, Equatable {
    /// Seconds per level.
    public let window: Double
    /// RMS level per window in dBFS. Digital silence is `LoudnessProfile.floorDb`.
    public let levels: [Float]

    public static let floorDb: Float = -120
    static let analysisRate = 8_000
    static let samplesPerWindow = 400 // 50 ms at 8 kHz

    public init(window: Double, levels: [Float]) {
        self.window = window
        self.levels = levels
    }

    public var duration: Double { Double(levels.count) * window }

    /// Decodes `url` once at 8 kHz mono and records the RMS level of every 50 ms.
    public static func measure(
        _ url: URL,
        ffmpeg: FFmpegRunner,
        duration: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LoudnessProfile {
        let levelsFile = FileManager.default.temporaryDirectory
            .appending(path: "atc-levels-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: levelsFile) }

        try await ffmpeg.run([
            "-i", url.path, "-map", "0:a:0",
            "-af", "aresample=\(analysisRate),aformat=channel_layouts=mono,asetnsamples=n=\(samplesPerWindow):p=0,astats=metadata=1:reset=1,"
                + "ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=\(levelsFile.path)",
            "-f", "null", "-",
        ], duration: duration, progress: progress)

        let text = try String(contentsOf: levelsFile, encoding: .utf8)
        let key = "lavfi.astats.Overall.RMS_level="
        let levels = text.split(separator: "\n").compactMap { line -> Float? in
            guard line.hasPrefix(key) else { return nil }
            let value = Float(line.dropFirst(key.count)) ?? floorDb
            return value.isFinite ? max(value, floorDb) : floorDb
        }
        return LoudnessProfile(window: Double(samplesPerWindow) / Double(analysisRate), levels: levels)
    }
}

/// The part of the main recording to keep, in seconds of the source file.
public struct TrimRange: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

extension LoudnessProfile {
    /// Keep this much before the first and after the last detected sound.
    public static let headPad = 0.5
    public static let tailPad = 1.0

    /// Finds where sound starts and stops, ignoring the room noise before and after.
    ///
    /// The threshold sits 35% of the way from the noise floor (quietest 10%) to the
    /// speech level (loudest 5%). Sound must fill half of a 0.5 s span to count,
    /// so a single click or bump does not.
    public func detectContent() -> TrimRange {
        let whole = TrimRange(start: 0, end: duration)
        guard levels.count > 20 else { return whole }

        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let peak = sorted[sorted.count * 95 / 100]
        guard peak - floor >= 10 else { return whole } // no clear difference between noise and sound
        let threshold = floor + (peak - floor) * 0.35

        let span = max(1, Int((0.5 / window).rounded()))
        let loud = levels.map { $0 > threshold ? 1 : 0 }
        // Running count of loud windows, so each span check is O(1).
        var prefix = [0]
        prefix.reserveCapacity(loud.count + 1)
        for l in loud { prefix.append(prefix.last! + l) }
        func isSound(_ i: Int) -> Bool {
            let end = min(i + span, loud.count)
            return loud[i] == 1 && (prefix[end] - prefix[i]) * 2 >= (end - i)
        }
        func isSoundEnding(_ i: Int) -> Bool {
            let start = max(0, i - span + 1)
            return loud[i] == 1 && (prefix[i + 1] - prefix[start]) * 2 >= (i + 1 - start)
        }

        guard let first = loud.indices.first(where: isSound),
              let last = loud.indices.last(where: isSoundEnding),
              last >= first
        else { return whole }

        return TrimRange(
            start: max(0, Double(first) * window - Self.headPad),
            end: min(duration, Double(last + 1) * window + Self.tailPad))
    }
}
