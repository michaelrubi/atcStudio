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
