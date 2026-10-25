# Spec amendments (proposed after Milestone 1)

Checked against `desert-ant-core` v4.1.0 source on 2026-10-25.

## Done differently in Milestone 1

1. **SwiftPM only, no `.xcodeproj`.** `Package.swift` is the project. `swift build` and
   `xcodebuild -scheme ATCStudio` both work, and Xcode opens it directly. A SwiftPM
   executable has no entitlements, so it is not sandboxed (same effect as
   `ENABLE_APP_SANDBOX = NO`). The Milestone 5 script will wrap the binary in a `.app`
   with an `Info.plist` and bundle id.
2. **Database code lives in `RestorationStation/Storage`.** The pipeline needs `Template`
   and `Speaker`, so they sit in the library, not the app.
3. **Extra mix columns.** The spec lists fixed numbers. Each is now a template column:
   `intro_lead_in_sec`, `ducking_db`, `duck_ramp_sec`, `intro_swell_db`,
   `intro_swell_sec`, `crossfade_sec`, `outro_underlap_sec`, `outro_fade_sec`.
4. **Names are unique, ignoring case,** for both templates and speakers. This makes
   speaker upsert safe ("pastor john" = "Pastor John").
5. **`desert-ant-core` is not added yet.** It comes in Milestone 3, so Milestone 1 and 2
   builds stay fast.

## Desert Ant facts that change later milestones

6. **License is source-available, not open source.** The SDK license is
   "Desert Ant Labs Source-Available License 1.0". Free under 100,000 monthly active
   devices per model. The app must show credit to Desert Ant Labs
   (https://license.desertant.com/attribution). The app code can still be open source.
   Plan: add the credit in an About window in Milestone 3.
7. **The SDK calls a license server** once per model per month. It sends an install id,
   model id, and bundle id. It sends no audio and no text. It never blocks the model.
   Optional `DesertAnt.apiKey`.
8. **`Title` needs the `MLX` trait.** Without it, `Title` builds as an empty stub.
   Milestone 3 dependency line:
   `.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.1.0", traits: ["MLX", "Xet"])`
   (`Xet` = faster parallel model downloads.)
9. **`Voz.transcribe` takes all samples in memory** (`samples: [Float]`). A 90 minute
   sermon at 16 kHz mono is about 350 MB. This is fine on the M2, but we should not hold
   several copies at once.

## Audio and release notes

10. **Use two-pass `loudnorm`.** One pass is less exact. Pass 1 measures, pass 2 applies
    with `linear=true`. Result lands closer to -16 LUFS.
11. **Use `AVURLAsset` for stem durations, not `ffprobe`.** One less binary to bundle.
12. **`ffmpeg` is not installed on this Mac.** Run `brew install ffmpeg` before
    Milestone 2. Homebrew `ffmpeg` is not static, so Milestone 5 needs a static `arm64`
    build from another source. Redistributing `ffmpeg` with `libmp3lame` brings GPL/LGPL
    duties (ship its license and source link).
13. **Gatekeeper on the M2.** An unsigned `.dmg` from GitHub is blocked on first open.
    Options: Developer ID signing and notarization (paid Apple account), or a one-time
    right-click Open on the M2. Decide before Milestone 5.

## Decided

14. **Stem and artwork files are copied into the app.** Each picked file is copied to
    `~/Library/Application Support/ATCStudio/Assets/<UUID>/<file name>`, and the template
    stores that path. Copies no saved template uses are deleted when a template is saved
    or deleted. The original file is never touched.

## Milestone 2 choices (as built)

15. **Two-pass `loudnorm` and `AVURLAsset` durations** (items 10 and 11) are in place.
    No `ffprobe` is needed.
16. **Exact intro timing.** VO starts when the lead-in ends, at the same moment the
    music starts to duck. Main audio starts at
    `introOffset = lead-in + intro VO length + swell time` (default 3 + VO + 1.5 s).
    The 2 s crossfade starts at that point. Music rises from duck to swell in 0.5 s.
17. **Bumper edge cases.** No intro VO: music plays for the lead-in, then crossfades.
    VO but no intro music: VO, then main, with no crossfade. No outro VO: the music swells
    when main ends.
18. **Progress comes from `-progress pipe:1`** (stdout), not from parsing stderr. Stderr
    is kept for errors and the loudness numbers.
19. **Speed.** A 60 minute file takes about 2 min 50 s on the M4 (two full passes).
    Expect longer on the M2.
20. **Each run makes a new export folder.** `YYYY-MM-DD_<file name>/`, local date, with
    `_2`, `_3`, … added instead of overwriting.

## Main-track trim (added after Milestone 2 review)

21. **Auto cut.** After a file is dropped, Restoration Station scans its loudness every
    50 ms (about 4 s for a 60 minute file). The cut threshold is 35% of the way from the
    room-noise level to the speech level. It keeps 0.5 s before the first sound and
    1.0 s after the last. One click or bump does not count as the start.
22. **Manual cut.** The Workspace shows the whole recording, plus a close-up of each cut.
    You can drag or click a cut, nudge it by ±0.1 s or ±1 s, and use Hear Start or
    Hear End (5 s of audio). Auto Cut and Keep Whole File reset the cuts.
23. **Limit.** The auto cut finds sound, not meaning. Pre-service chatter
    ("are we recording?") counts as sound, so move the cut by hand for that.
    Milestone 3 could suggest a start from the first transcribed words.
24. **Milestone 3 timestamps.** ML timestamps are in source-file seconds. Convert them with
    `CompositionResult.masterTime(forSourceTime:)` = `introOffset + (t - trim.start)`.

## Milestone 3 choices (as built)

25. **Models are optional.** Make MP3 (trim + bumpers + -16 LUFS) needs only `ffmpeg`.
    The switch "Clean audio, transcript, speakers, and titles" adds Clear and the ML
    models, and works only once they are downloaded. The download sheet shows once, on
    first launch; after that, use the Models tab.
26. **Clear runs only on the kept part** (after the trim), with its own mastering off
    (`.bypass`), because our ffmpeg pass masters to -16 LUFS. All ML runs on that clean
    clip, so master time = ML time + `introOffset`.
27. **Title gives 1 title and a 1–2 sentence description per passage.** For 3 title ideas
    we describe the whole message, its first half, and its second half. The summary is
    the whole-message description (1–2 sentences, not 2–3).
28. **Title needs an Xcode build.** It runs on the GPU through MLX. `swift build` does not
    compile MLX's GPU code, so a `swift run` build skips titles (the other 5 models still
    run). `xcodebuild` needs Xcode's Metal Toolchain:
    `xcodebuild -downloadComponent MetalToolchain` (one time).
29. **Language is English** for Align (`en`). Voz detects language by itself.
30. **`Xet` trait left off.** Plain HTTPS downloads work and need fewer dependencies.
31. **Desert Ant credit** ("On-device AI by Desert Ant Labs 🐜", linked to desertant.com)
    is in the About panel and the Models tab.
