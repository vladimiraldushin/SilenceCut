# SilenceCut

Native macOS video editor with automatic silence removal. Built for content creators who record vertical videos (Reels, Shorts, TikTok) and want to quickly remove pauses.

## Features

- **Automatic Silence Detection** — Analyzes audio track and detects pauses using high-performance vDSP/Accelerate framework
- **Adjustable Sensitivity** — Threshold (dB), minimum duration, padding controls with presets (Aggressive/Normal/Conservative)
- **Visual Timeline** — Waveform display with color-coded speech/silence fragments
- **Fragment Editing** — Trim, split, extend, delete fragments by dragging edges or using context menu
- **Real-time Preview** — AVPlayer-based video preview
- **Hardware-Accelerated Export** — Uses VideoToolbox for H.264/HEVC encoding via Apple Silicon Media Engine
- **Undo/Redo** — Full history with Cmd+Z / Cmd+Shift+Z
- **Drag & Drop** — Drop video files directly into the app

## Tech Stack

- **Swift 5.10** + **SwiftUI** + **AppKit** (hybrid UI)
- **AVFoundation** — Video import, playback, composition, export
- **Accelerate/vDSP** — High-performance audio analysis (SIMD-optimized)
- **Metal** — GPU-accelerated waveform and timeline rendering
- **VideoToolbox** — Hardware H.264/HEVC encoding

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon recommended (M1/M2/M3/M4)

## Build

```bash
# Clone
git clone https://github.com/vladimiraldushin/SilenceCut.git
cd SilenceCut

# Build with Swift Package Manager
swift build

# Or open in Xcode
open Package.swift
```

## Architecture

```
SilenceCut/
├── App/              # App entry point
├── Models/           # Data models (Fragment, Project, Settings)
├── Engine/
│   ├── Audio/        # SilenceDetector, WaveformGenerator
│   ├── Video/        # VideoExporter
│   └── Timeline/     # TimelineEngine
├── Views/
│   ├── Timeline/     # Timeline UI components
│   ├── Preview/      # Video preview
│   └── Panels/       # Silence detection, fragment list, export
└── Resources/
```

## License

MIT
