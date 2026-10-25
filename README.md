# ATC Studio

As The Church Studio: drop in raw Sunday sermon or podcast audio and get a mastered,
denoised, bumper-stitched, speaker-labeled episode package.

The audio and ML engine is the `RestorationStation` library.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 15 or newer
- Xcode 26 / Swift 6.2 or newer
- `ffmpeg`: `brew install ffmpeg` for local development
- For Title suggestions, Xcode's Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`

## Build and run

```bash
swift build
swift test
swift run ATCStudio
ATC_ML_TESTS=1 swift test --filter MLPipelineTests   # downloads ~0.9 GB of models once
```

You can also open `Package.swift` in Xcode and run the `ATCStudio` scheme.

## Layout

```
Package.swift
Sources/
  ATCStudio/                 SwiftUI app (window, tabs, views)
  RestorationStation/
    Audio/                   FFmpegRunner, MixPlan, AudioCompositionService, trim
    ML/                      Desert Ant models, MLPipelineActor, EpisodeAnalysis
    Storage/                 GRDB models, migrations, DatabaseManager, assets
Tests/
  RestorationStationTests/   Database, mix-plan, and real-ffmpeg tests (Swift Testing)
scripts/                     Release scripts (Milestone 5)
```

## Credits

On-device AI by [Desert Ant Labs](https://desertant.com) 🐜 (Clear, Voz, Who, Align, Uhm, Title),
under the Desert Ant Labs Source-Available License 1.0.

## Data

- Database: `~/Library/Application Support/ATCStudio/atc_studio.sqlite`
- Exports: `~/Movies/ATC Studio Exports/` (from Milestone 4)

## Status

- [x] Milestone 1: project, SQLite storage, Templates and Speakers tabs
- [x] Milestone 2: FFmpeg mixing and auto-ducking
- [x] Milestone 3: Desert Ant ML pipeline
- [ ] Milestone 4: speaker mapping and export
- [ ] Milestone 5: release DMG
