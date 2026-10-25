# ATC Studio

As The Church Studio: drop in raw Sunday sermon or podcast audio and get a mastered,
denoised, bumper-stitched, speaker-labeled episode package.

The audio and ML engine is the `RestorationStation` library.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 15 or newer
- Xcode 26 / Swift 6.2 or newer
- `ffmpeg` (from Milestone 2): `brew install ffmpeg` for local development

## Build and run

```bash
swift build
swift test
swift run ATCStudio
```

You can also open `Package.swift` in Xcode and run the `ATCStudio` scheme.

## Layout

```
Package.swift
Sources/
  ATCStudio/                 SwiftUI app (window, tabs, views)
  RestorationStation/
    Audio/                   FFmpegRunner, MixPlan, AudioCompositionService
    Storage/                 GRDB models, migrations, DatabaseManager, assets
Tests/
  RestorationStationTests/   Database, mix-plan, and real-ffmpeg tests (Swift Testing)
scripts/                     Release scripts (Milestone 5)
```

## Data

- Database: `~/Library/Application Support/ATCStudio/atc_studio.sqlite`
- Exports: `~/Movies/ATC Studio Exports/` (from Milestone 4)

## Status

- [x] Milestone 1: project, SQLite storage, Templates and Speakers tabs
- [x] Milestone 2: FFmpeg mixing and auto-ducking
- [ ] Milestone 3: Desert Ant ML pipeline
- [ ] Milestone 4: speaker mapping and export
- [ ] Milestone 5: release DMG
