import Foundation

/// A gain point on a stem's volume envelope. `gain` is linear (1 = 0 dB, 0 = silence).
public struct GainPoint: Sendable, Equatable {
    public var time: Double
    public var gain: Double

    public init(_ time: Double, _ gain: Double) {
        self.time = time
        self.gain = gain
    }
}

func linearGain(dB: Double) -> Double { pow(10, dB / 20) }

/// Where every piece lands on the master timeline, worked out from stem durations
/// and the template's envelope settings. Pure math, no ffmpeg.
///
/// Intro (music + VO):
///   music fades in from silence to the plateau (`duckingDb`, e.g. -24 dB) during the
///   lead-in → holds steady under the VO and post-VO buffer → crossfades into main.
/// Outro (music + VO):
///   music fades in to the plateau (`duckingDb`) under the last `outroUnderlap` seconds
///   of main → holds steady under the VO and post-VO buffer → fades out to silence.
public struct MixPlan: Sendable, Equatable {
    public static let sampleRate = 44_100.0

    public let mainDuration: Double

    /// Seconds from the start of the master to the first sample of the main audio.
    /// Add this to every transcript and speaker timestamp.
    public let introOffset: Double
    /// Intro-to-main crossfade length. 0 means a straight join.
    public let crossfade: Double
    /// Length of the intro bed (music + VO) before it is crossfaded into main. 0 if no intro.
    public let introBedLength: Double
    public let introVOStart: Double
    /// Empty when the template has no intro music.
    public let introMusicGain: [GainPoint]

    /// Master time where the outro bus (music + VO) starts. Nil if no outro.
    public let outroStart: Double?
    public let outroLength: Double
    /// Outro VO start, relative to `outroStart`.
    public let outroVOStart: Double
    public let outroMusicGain: [GainPoint]

    public let totalDuration: Double

    /// Master time where the main audio ends.
    public var mainEnd: Double { introOffset + mainDuration }
    public var hasIntro: Bool { introBedLength > 0 }
    public var hasOutro: Bool { outroStart != nil }

    public init(
        template: Template,
        mainDuration: Double,
        hasIntroMusic: Bool,
        introVODuration: Double?,
        hasOutroMusic: Bool,
        outroVODuration: Double?
    ) {
        self.mainDuration = mainDuration
        let rampSec = max(0, template.duckRampSec)
        let duck = linearGain(dB: template.duckingDb)

        // MARK: Intro
        let crossfadeSec = max(0, template.crossfadeSec)
        switch (hasIntroMusic, introVODuration) {
        case (true, let vo?):
            let leadIn = max(0, template.introLeadInSec)
            let voEnd = leadIn + vo
            let swellSec = max(0, template.introSwellSec)
            introVOStart = leadIn
            introOffset = voEnd + swellSec
            introMusicGain = [
                GainPoint(0, 0),
                GainPoint(min(rampSec, leadIn), duck),
                GainPoint(leadIn, duck),
                GainPoint(voEnd, duck),
                GainPoint(introOffset, duck),
            ]
        case (true, nil):
            let leadIn = max(0, template.introLeadInSec)
            introVOStart = 0
            introOffset = leadIn
            introMusicGain = [
                GainPoint(0, 0),
                GainPoint(min(rampSec, leadIn), duck),
            ]
        case (false, let vo?):
            // Usually a finished bumper with its music mixed in: the main audio
            // crossfades over its last seconds so the music never cuts off.
            let overlap = min(crossfadeSec, vo / 2, mainDuration / 2)
            introVOStart = 0
            introOffset = vo - overlap
            introMusicGain = []
        case (false, nil):
            introVOStart = 0
            introOffset = 0
            introMusicGain = []
        }
        if hasIntroMusic {
            crossfade = introOffset > 0 ? min(crossfadeSec, mainDuration / 2) : 0
        } else if let vo = introVODuration {
            crossfade = vo - introOffset
        } else {
            crossfade = 0
        }
        introBedLength = introOffset + crossfade

        // MARK: Outro
        let underlap = min(max(0, template.outroUnderlapSec), mainDuration)
        let fade = max(0, template.outroFadeSec)
        switch (hasOutroMusic, outroVODuration) {
        case (true, let vo):
            let voEnd = underlap + (vo ?? 0)
            outroVOStart = underlap
            outroLength = voEnd + rampSec + fade
            outroMusicGain = [
                GainPoint(0, 0),
                GainPoint(underlap, duck),
                GainPoint(voEnd, duck),
                GainPoint(voEnd + rampSec, duck),
                GainPoint(voEnd + rampSec + fade, 0),
            ]
        case (false, let vo?):
            outroVOStart = underlap
            outroLength = underlap + vo
            outroMusicGain = []
        case (false, nil):
            outroVOStart = 0
            outroLength = 0
            outroMusicGain = []
        }
        let end = introOffset + mainDuration
        outroStart = outroLength > 0 ? end - underlap : nil
        totalDuration = max(end, (outroStart ?? 0) + outroLength)
    }
}

// MARK: - ffmpeg filtergraph

/// Input indices for each stem in the ffmpeg command. Main audio is always present.
struct StemInputs {
    var main = 0
    /// Part of the main file to keep, in source seconds. Nil keeps it all.
    var mainTrim: TrimRange?
    var introMusic: Int?
    var introVO: Int?
    var outroMusic: Int?
    var outroVO: Int?
}

extension MixPlan {
    /// Builds a `-filter_complex` graph that ends in the label `[prog]` (mixed, not yet mastered).
    func filterGraph(_ inputs: StemInputs) -> String {
        var chains: [String] = []

        func prepare(_ input: Int, _ label: String, trim: TrimRange? = nil) {
            let cut = trim.map { "atrim=start=\(seconds($0.start)):end=\(seconds($0.end)),asetpts=PTS-STARTPTS," } ?? ""
            chains.append("[\(input):a:0]\(cut)aresample=\(Int(Self.sampleRate)),"
                + "aformat=sample_fmts=fltp:channel_layouts=stereo,asetpts=PTS-STARTPTS[\(label)]")
        }
        /// Pads or trims to exactly `length` seconds, restarting timestamps at 0.
        func fit(_ length: Double) -> String {
            "apad,atrim=end=\(seconds(length)),asetpts=PTS-STARTPTS"
        }
        func envelope(_ points: [GainPoint]) -> String {
            "asetnsamples=n=256,volume='\(GainEnvelope.expression(points))':eval=frame"
        }
        func delay(_ time: Double) -> String {
            "adelay=delays=\(Int((time * Self.sampleRate).rounded()))S:all=1"
        }
        func mix(_ labels: [String], into out: String) -> String {
            guard labels.count > 1 else { return labels[0] }
            chains.append(labels.map { "[\($0)]" }.joined()
                + "amix=inputs=\(labels.count):duration=longest:normalize=0[\(out)]")
            return out
        }

        prepare(inputs.main, "main", trim: inputs.mainTrim)
        var program = "main"

        if hasIntro {
            var parts: [String] = []
            if let i = inputs.introMusic {
                prepare(i, "im")
                chains.append("[im]\(fit(introBedLength)),\(envelope(introMusicGain))[imx]")
                parts.append("imx")
            }
            if let i = inputs.introVO {
                prepare(i, "iv")
                chains.append("[iv]\(delay(introVOStart)),\(fit(introBedLength))[ivx]")
                parts.append("ivx")
            }
            let bed = mix(parts, into: "bed")
            if crossfade > 0 {
                chains.append("[\(bed)][main]acrossfade=d=\(seconds(crossfade)):c1=tri:c2=tri[body]")
            } else {
                chains.append("[\(bed)][main]concat=n=2:v=0:a=1[body]")
            }
            program = "body"
        }

        if let outroStart {
            var parts: [String] = []
            if let i = inputs.outroMusic {
                prepare(i, "om")
                chains.append("[om]\(fit(outroLength)),\(envelope(outroMusicGain))[omx]")
                parts.append("omx")
            }
            if let i = inputs.outroVO {
                prepare(i, "ov")
                chains.append("[ov]\(delay(outroVOStart)),\(fit(outroLength))[ovx]")
                parts.append("ovx")
            }
            let bus = mix(parts, into: "obus")
            chains.append("[\(bus)]\(delay(outroStart))[outro]")
            chains.append("[\(program)][outro]amix=inputs=2:duration=longest:normalize=0[prog]")
        } else {
            chains.append("[\(program)]anull[prog]")
        }

        return chains.joined(separator: ";")
    }
}

/// Seconds as a fixed-point string for ffmpeg (never locale-formatted).
func seconds(_ value: Double) -> String { String(format: "%.6f", value) }

enum GainEnvelope {
    /// A piecewise-linear ffmpeg `volume` expression in `t` through `points`.
    /// Before the first point the first gain holds; after the last, the last gain holds.
    static func expression(_ points: [GainPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "1" }
        var expr = seconds(last.gain)
        for (a, b) in zip(points, points.dropFirst()).reversed() where b.time > a.time {
            let slope = (b.gain - a.gain) / (b.time - a.time)
            let segment = "\(seconds(a.gain))+(\(seconds(slope)))*(t-\(seconds(a.time)))"
            expr = "if(lt(t,\(seconds(b.time))),\(segment),\(expr))"
        }
        return "if(lt(t,\(seconds(first.time))),\(seconds(first.gain)),\(expr))"
    }
}
