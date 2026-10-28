import Foundation
import Testing
@testable import RestorationStation

@Suite struct MixPlanTests {
    let template = Template(name: "Test") // defaults: lead-in 3, duck -24 over 1.5, hold 1.5, xfade 2, outro 3/3

    @Test func fullIntroAndOutroTimings() {
        let plan = MixPlan(template: template, mainDuration: 600,
                           hasIntroMusic: true, introVODuration: 10,
                           hasOutroMusic: true, outroVODuration: 8)
        #expect(plan.introVOStart == 3)
        #expect(plan.introOffset == 14.5) // 3 lead-in + 10 VO + 1.5 hold
        #expect(plan.crossfade == 2)
        #expect(plan.introBedLength == 16.5)
        #expect(plan.mainEnd == 614.5)
        #expect(plan.outroStart == 611.5)
        #expect(plan.outroVOStart == 3)
        #expect(plan.outroLength == 15.5) // 3 underlap + 8 VO + 1.5 hold + 3 fade
        #expect(plan.totalDuration == 627)

        let duck = pow(10, -24.0 / 20)
        #expect(plan.introMusicGain.map(\.time) == [0, 1.5, 3, 13, 14.5])
        #expect(plan.introMusicGain.map(\.gain) == [0, duck, duck, duck, duck])
        #expect(plan.outroMusicGain.map(\.gain) == [0, duck, duck, duck, 0])
    }

    @Test func noBumpersMeansNoOffset() {
        let plan = MixPlan(template: template, mainDuration: 60,
                           hasIntroMusic: false, introVODuration: nil,
                           hasOutroMusic: false, outroVODuration: nil)
        #expect(plan.introOffset == 0)
        #expect(!plan.hasIntro)
        #expect(!plan.hasOutro)
        #expect(plan.totalDuration == 60)
    }

    @Test func musicOnlyIntroCrossfadesAfterLeadIn() {
        let plan = MixPlan(template: template, mainDuration: 60,
                           hasIntroMusic: true, introVODuration: nil,
                           hasOutroMusic: false, outroVODuration: nil)
        let duck = pow(10, -24.0 / 20)
        #expect(plan.introOffset == 3)
        #expect(plan.crossfade == 2)
        #expect(plan.introMusicGain == [GainPoint(0, 0), GainPoint(1.5, duck)])
    }

    @Test func voiceOnlyIntroCrossfadesOverItsTail() {
        let plan = MixPlan(template: template, mainDuration: 60,
                           hasIntroMusic: false, introVODuration: 7,
                           hasOutroMusic: false, outroVODuration: 4)
        #expect(plan.introOffset == 5) // main starts under the last 2 s of the bumper
        #expect(plan.crossfade == 2)
        #expect(plan.introBedLength == 7)
        #expect(plan.outroStart == 62)
        #expect(plan.totalDuration == 69)
    }

    @Test func voiceOnlyIntroJoinsStraightWhenCrossfadeIsOff() {
        var noFade = template
        noFade.crossfadeSec = 0
        let plan = MixPlan(template: noFade, mainDuration: 60,
                           hasIntroMusic: false, introVODuration: 7,
                           hasOutroMusic: false, outroVODuration: nil)
        #expect(plan.introOffset == 7)
        #expect(plan.crossfade == 0)
        #expect(plan.introBedLength == 7)
    }

    @Test func crossfadeAndUnderlapClampToShortMainAudio() {
        let plan = MixPlan(template: template, mainDuration: 2,
                           hasIntroMusic: true, introVODuration: nil,
                           hasOutroMusic: true, outroVODuration: nil)
        #expect(plan.crossfade == 1)
        #expect(plan.outroStart == plan.introOffset)
    }

    @Test func envelopeExpressionInterpolates() {
        let expr = GainEnvelope.expression([GainPoint(0, 1), GainPoint(2, 0)])
        #expect(expr == "if(lt(t,0.000000),1.000000,if(lt(t,2.000000),1.000000+(-0.500000)*(t-0.000000),0.000000))")
    }

    @Test func envelopeSkipsZeroLengthSegments() {
        let expr = GainEnvelope.expression([GainPoint(0, 0), GainPoint(0, 0.5), GainPoint(1, 0.5)])
        #expect(!expr.contains("inf") && !expr.contains("nan"))
    }

    @Test func parsesLoudnormJSON() {
        let log = """
        [Parsed_loudnorm_12 @ 0x600]
        {
        \t"input_i" : "-24.31",
        \t"input_tp" : "-3.10",
        \t"input_lra" : "6.20",
        \t"input_thresh" : "-34.80",
        \t"output_i" : "-16.02",
        \t"output_tp" : "-1.50",
        \t"output_lra" : "5.10",
        \t"output_thresh" : "-26.40",
        \t"normalization_type" : "dynamic",
        \t"target_offset" : "0.02"
        }
        """
        let m = LoudnessMeasurement(log: log)
        #expect(m?.inputI == "-24.31")
        #expect(m?.targetOffset == "0.02")
        #expect(LoudnessMeasurement(log: log.replacingOccurrences(of: "-24.31", with: "-inf")) == nil)
    }
}
