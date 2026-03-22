# SilenceCut

Native macOS video editor with automatic silence removal. Optimized for Apple Silicon (M1-M4).

## Architecture

**Key principle**: AVMutableComposition is a disposable render artifact, not the data model. Own EDL (Edit Decision List) model on top of AVFoundation.

```
Sources/
├── RECore/           — Domain models (TimelineClip, EditTimeline, Project). ZERO AVFoundation deps
├── RETimeline/       — CompositionBuilder: EDL → AVMutableComposition
├── REAudioAnalysis/  — SilenceDetector, WaveformGenerator (vDSP)
├── REExport/         — AVAssetWriter export pipeline
├── REUI/             — SwiftUI + AppKit UI components
└── SilenceCutApp/    — App entry point
```

## Build

```bash
swift build
swift test
open Package.swift  # Opens in Xcode
```

## Requirements

- macOS 14.0 (Sonoma)+
- Swift 5.10+
- Apple Silicon recommended

## Design Decisions

| Decision | Why |
|----------|-----|
| EDL model over AVMutableComposition | AVFoundation has no "clip" abstraction. Direct mutation breaks |
| Full AVPlayer recreation | `replaceCurrentItem` is unreliable with repeated updates |
| AppKit NSView for timeline | SwiftUI: gesture conflicts, excessive redraws, no CALayer control |
| Command Pattern for undo | Memento snapshots too heavy with thumbnail caches |
| vDSP for silence detection | CoreML dispatch overhead 2-4x for small ops |
| CMTime everywhere | Float64 seconds cause frame drift at 29.97/23.976 fps |
