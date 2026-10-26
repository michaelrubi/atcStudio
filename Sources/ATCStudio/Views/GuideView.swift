import SwiftUI

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                GuideSection(title: "Quick Start Workflow", systemImage: "play.circle.fill") {
                    GuideStep(
                        number: 1,
                        title: "Drop or choose your recording",
                        detail: "Drag a raw service or podcast recording into the Workspace tab. ATC Studio automatically scans the loudness profile and detects worship music vs. spoken word."
                    )
                    GuideStep(
                        number: 2,
                        title: "Verify your start and end cuts",
                        detail: "Use Sermon Only to automatically strip opening and closing worship sets, or Auto Cut to trim room silence. Use Hear Start and Hear End (or the ±0.1 s / ±1 s nudge buttons) to fine-tune the exact boundaries."
                    )
                    GuideStep(
                        number: 3,
                        title: "Pick a template and AI preset",
                        detail: "Select Teaching or Podcast (or your own custom template), choose whether to run all AI tools or a fast MP3-only mix, and click Make Episode."
                    )
                    GuideStep(
                        number: 4,
                        title: "Review and export",
                        detail: "Pick a suggested title, assign speaker names, review the transcript and chapters, and click Save Episode Package to export the mastered MP3, Podbean show notes, transcript, and artwork."
                    )
                }

                GuideSection(title: "Music Mixing & -16 LUFS Mastering", systemImage: "slider.horizontal.3") {
                    GuideBullet(
                        title: "Single-plateau music bed (-24 dB default)",
                        detail: "Intro music fades in from silence to your Music under voice level (default -24 dB) during the lead-in, plateaus before the voice-over starts, holds steady for the entire voice-over and post-voice hold, and crossfades into the message—never creating two loud peaks."
                    )
                    GuideBullet(
                        title: "Smooth outro fade",
                        detail: "Outro music fades in to the same plateau under the speaker's final words, holds steady under any outro voice-over, and fades directly to silence."
                    )
                    GuideBullet(
                        title: "Any voice-over length works",
                        detail: "Template sliders only control transition timings (fade-in, lead-in, hold, and crossfade). Your intro or outro voice-over file can be any length—the music bed automatically stays plateaued underneath until the voice-over finishes."
                    )
                    GuideBullet(
                        title: "Two-pass -16 LUFS mastering",
                        detail: "Every episode is measured and normalized using a two-pass EBU R128 loudness pass (-16 LUFS integrated loudness, -1.5 dBTP true peak, 192 kbps MP3) so every episode publishes at a consistent broadcast volume."
                    )
                }

                GuideSection(title: "Trimming & Worship Detection", systemImage: "timeline.selection") {
                    GuideBullet(
                        title: "Sermon Only vs. Auto Cut",
                        detail: "Music sections detected by on-device sound classification are highlighted in purple on the timeline. Sermon Only places cuts right after opening worship and right before closing worship. Auto Cut keeps everything between the first and last non-silent sound."
                    )
                    GuideBullet(
                        title: "Close-up trim windows",
                        detail: "Drag the green (start) and orange (end) handles on either the full timeline or the 30-second close-up views, and click Hear Start or Hear End to audition 5 seconds at the cut point."
                    )
                }

                GuideSection(title: "Templates, Speakers & AI Models", systemImage: "cpu") {
                    GuideBullet(
                        title: "Templates (Podcast & Teaching)",
                        detail: "When you pick intro/outro stems or artwork in the Templates tab, ATC Studio saves a managed copy inside Application Support so moving or deleting the original file in Finder will not break your template."
                    )
                    GuideBullet(
                        title: "Custom vocabulary",
                        detail: "Add church names, pastors' names, and biblical terms (comma-separated) in your template so the transcription model spells them accurately."
                    )
                    GuideBullet(
                        title: "100% on-device AI",
                        detail: "Clear cleans sanctuary acoustics and room noise (with its internal limiter bypassed so the -16 LUFS master controls final gain), Voz transcribes speech, Who separates speakers, Align & Uhm refine timestamps and filler words, and Title drafts episode titles, summaries, and chapters."
                    )
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to Use ATC Studio")
                .font(.title2.bold())
            Text("A quick guide to trimming recordings, configuring templates, mixing music beds, and mastering episodes.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct GuideSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GuideBullet: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
