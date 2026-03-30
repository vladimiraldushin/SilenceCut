import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import PhotosUI
#endif
import AVFoundation
import RECore
import RETimeline
import REAudioAnalysis
import REExport

/// Main editor view model — owns the timeline, player, and coordinates changes.
@Observable
public class EditorViewModel {
    public var project = Project()
    public var timeline = EditTimeline()
    public private(set) var player: AVPlayer?
    public var playheadPosition: CMTime = .zero
    public var isPlaying = false
    public var isImporting = false
    public var statusMessage = ""
    public var pixelsPerSecond: Double = 100
    public var selectedClipId: UUID?
    public var waveformData: WaveformData?

    // Silence detection
    public var silenceSettings = SilenceSettings.normal
    public var silenceResult: SilenceDetectionResult?
    public var isDetectingSilence = false
    public var detectionProgress: Double = 0

    // Video aspect ratio (9:16 for vertical, 16:9 for horizontal)
    public var videoAspectRatio: CGFloat = 9.0 / 16.0

    // Subtitles
    public var subtitleEntries: [SubtitleEntry] = []
    public var subtitleStyle: SubtitleStyle = .classic
    public var isTranscribing = false
    public var transcriptionProgress: Double = 0
    public var transcriptionPhase: String = ""
    public var transcriptionDetail: String = ""
    public var showSubtitles = true
    public var showSafeZones = false

    // Auto-split export
    public var autoSplitEnabled = false
    public var autoSplitDuration: Double = 60  // seconds

    // Export
    public var isExporting = false
    public var exportProgress: Double = 0
    public var exportPreset: ExportPreset = .high

    // Undo/Redo (Memento — snapshot of EditTimeline)
    private var undoStack: [EditTimeline] = []
    private var redoStack: [EditTimeline] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private var timeObserver: Any?

    // Smooth scrubbing state
    private var isSeekInProgress = false
    private var chaseTime: CMTime = .zero

    // ASR model manager (cached between transcriptions, shared lifecycle)
    public let modelManager = ModelManager()

    public init() {
        // Clean up leftover temp files from previous sessions (crashes, etc.)
        Self.cleanupTempFiles()
    }

    /// Remove all silencecut_* temp files from tmp directory
    static func cleanupTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("silencecut_") {
                try? FileManager.default.removeItem(at: file)
                print("[Cleanup] Removed: \(file.lastPathComponent)")
            }
        }
    }

    // MARK: - File Import

    public func importVideo(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        project.sourceURL = url
        project.name = url.deletingPathExtension().lastPathComponent

        // Reset state from previous project
        subtitleEntries = []
        silenceResult = nil
        selectedClipId = nil
        playheadPosition = .zero
        isPlaying = false
        isImporting = true
        statusMessage = "Загрузка видео..."
        undoStack.removeAll()
        redoStack.removeAll()

        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)

                // Detect video aspect ratio (9:16 vertical, 16:9 horizontal)
                if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await videoTrack.load(.naturalSize)
                    let transform = try await videoTrack.load(.preferredTransform)
                    let transformed = size.applying(transform)
                    let w = abs(transformed.width)
                    let h = abs(transformed.height)
                    if h > 0 { videoAspectRatio = w / h }
                }

                let availableRange = CMTimeRange(start: .zero, duration: duration)

                let clip = TimelineClip(
                    sourceURL: url,
                    availableRange: availableRange,
                    sourceRange: availableRange
                )
                timeline = EditTimeline(clips: [clip])
                statusMessage = "Загружено: \(url.lastPathComponent)"
                await rebuildPreview()

                // Generate waveform
                waveformData = try await WaveformGenerator.generate(from: url)
                isImporting = false
            } catch {
                statusMessage = "Ошибка: \(error.localizedDescription)"
                isImporting = false
            }
        }
    }

    // MARK: - Preview Rebuild (debounced)

    private var rebuildTask: Task<Void, Never>?

    @MainActor
    public func rebuildPreview() async {
        let currentTime = player?.currentTime() ?? .zero

        removeTimeObserver()
        player?.pause()
        player = nil

        guard timeline.enabledClipCount > 0 else {
            playheadPosition = .zero
            isPlaying = false
            return
        }

        do {
            let result = try await CompositionBuilder.build(from: timeline)
            let playerItem = AVPlayerItem(asset: result.composition)
            if let videoComp = result.videoComposition {
                playerItem.videoComposition = videoComp
            }
            if let audioMix = result.audioMix {
                playerItem.audioMix = audioMix
            }
            player = AVPlayer(playerItem: playerItem)

            // Clamp playhead: if beyond new duration, go to start
            let maxTime = timeline.duration
            let seekTime: CMTime
            if CMTimeCompare(currentTime, maxTime) >= 0 || CMTimeCompare(currentTime, .zero) < 0 {
                seekTime = .zero
            } else {
                seekTime = currentTime
            }
            await player?.seek(to: seekTime)
            playheadPosition = seekTime
            isPlaying = false

            setupTimeObserver()
        } catch {
            statusMessage = "Ошибка превью: \(error.localizedDescription)"
        }
    }

    /// Debounced rebuild (for trim gestures — 100ms delay)
    public func debouncedRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await rebuildPreview()
        }
    }

    // MARK: - Playback

    /// True while seeking before play — blocks time observer from overwriting playheadPosition
    private var isSeeking = false

    public func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            playheadPosition = player.currentTime()
            isPlaying = false
        } else {
            // Seek to playheadPosition FIRST, play only after seek completes.
            // Block time observer during seek to prevent it overwriting playheadPosition.
            isSeeking = true
            let targetTime = playheadPosition
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self, finished else { return }
                Task { @MainActor in
                    self.isSeeking = false
                    self.isPlaying = true
                    self.player?.play()
                }
            }
        }
    }

    // MARK: - Smooth Scrubbing (chase-seek pattern)

    public func seekSmoothly(to time: CMTime) {
        playheadPosition = time
        chaseTime = time
        // Always chase-seek the player (even when paused) so play() starts from the right spot
        if !isSeekInProgress {
            trySeekToChaseTime()
        }
    }

    private func trySeekToChaseTime() {
        guard let player else { return }
        isSeekInProgress = true
        let target = chaseTime
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            if self.chaseTime != target {
                self.trySeekToChaseTime()
            } else {
                self.isSeekInProgress = false
            }
        }
    }

    // MARK: - Timeline Operations

    /// Clear subtitles when timeline changes (they were transcribed from a specific edit state)
    private func invalidateSubtitles() {
        if !subtitleEntries.isEmpty {
            subtitleEntries = []
            statusMessage = "Субтитры сброшены (транскрибируйте заново)"
            print("[Editor] Subtitles invalidated due to timeline change")
        }
    }

    public func splitAtPlayhead() {
        guard let idx = timeline.clipIndex(at: playheadPosition) else { return }
        saveUndoState()
        invalidateSubtitles()
        timeline.splitClip(at: idx, splitTime: playheadPosition)
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteClip(id: UUID) {
        saveUndoState()
        invalidateSubtitles()
        timeline.deleteClip(id: id)
        if selectedClipId == id { selectedClipId = nil }
        playheadPosition = .zero
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteSelectedClip() {
        guard let id = selectedClipId else { return }
        deleteClip(id: id)
    }

    public func toggleClip(id: UUID) {
        saveUndoState()
        invalidateSubtitles()
        timeline.toggleClip(id: id)
        Task { @MainActor in await rebuildPreview() }
    }

    private var isTrimming = false

    /// Called continuously during trim drag. Saves undo only once at start.
    public func trimClip(id: UUID, newSourceRange: CMTimeRange) {
        if !isTrimming {
            saveUndoState()
            isTrimming = true
        }
        invalidateSubtitles()
        timeline.trimClip(id: id, newSourceRange: newSourceRange)
        debouncedRebuild()
    }

    /// Call when trim gesture ends to reset the flag.
    public func trimEnded() {
        isTrimming = false
    }

    // MARK: - Undo/Redo

    private func saveUndoState() {
        undoStack.append(timeline)
        redoStack.removeAll()
        // Limit stack depth
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(timeline)
        timeline = previous
        Task { @MainActor in await rebuildPreview() }
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(timeline)
        timeline = next
        Task { @MainActor in await rebuildPreview() }
    }

    // MARK: - Silence Detection

    public func detectSilence() {
        guard let url = project.sourceURL else { return }
        invalidateSubtitles()
        isDetectingSilence = true
        detectionProgress = 0

        Task { @MainActor in
            do {
                let result = try await SilenceDetector.detect(
                    in: url,
                    settings: silenceSettings
                ) { progress in
                    Task { @MainActor in
                        self.detectionProgress = progress
                    }
                }

                silenceResult = result
                print("[SilenceCut] Detection: \(result.pauseCount) pauses, " +
                      "\(String(format: "%.1f", result.totalSilenceDuration))s silence, " +
                      "\(result.speechRanges.count) speech regions")

                // Replace timeline with speech clips
                guard let sourceURL = project.sourceURL else { return }
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration)
                let availableRange = CMTimeRange(start: .zero, duration: duration)

                saveUndoState()
                timeline = EditTimeline.fromSpeechRanges(
                    result.speechRanges,
                    sourceURL: sourceURL,
                    availableRange: availableRange
                )

                await rebuildPreview()
                statusMessage = "Удалено пауз: \(result.pauseCount), сохранено \(String(format: "%.1f", result.totalSilenceDuration)) с"
            } catch {
                statusMessage = "Ошибка детекции: \(error.localizedDescription)"
            }
            isDetectingSilence = false
        }
    }

    /// Restore original (single clip, full video)
    public func restoreOriginal() {
        guard let url = project.sourceURL else { return }
        invalidateSubtitles()
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let availableRange = CMTimeRange(start: .zero, duration: duration)
                let clip = TimelineClip(
                    sourceURL: url,
                    availableRange: availableRange,
                    sourceRange: availableRange
                )
                timeline = EditTimeline(clips: [clip])
                silenceResult = nil
                await rebuildPreview()
                statusMessage = "Оригинал восстановлен"
            } catch {
                statusMessage = "Ошибка восстановления: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Transcription

    public func transcribe() {
        guard project.sourceURL != nil else { return }
        guard timeline.enabledClipCount > 0 else {
            statusMessage = "Нет клипов для транскрибации"
            return
        }
        isTranscribing = true
        transcriptionProgress = 0
        transcriptionPhase = "Экспорт монтажа..."
        transcriptionDetail = ""

        // Clean up old temp files before creating new ones
        Self.cleanupTempFiles()

        Task { @MainActor in
            do {
                // Step 1: Export edited timeline to temp file (so subtitles match final video)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("silencecut_transcribe_\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: tempURL) }

                transcriptionPhase = "Экспорт монтажа..."
                try await ExportService.export(
                    timeline: timeline,
                    to: tempURL,
                    preset: .medium
                ) { p in
                    Task { @MainActor in
                        // 0-30% progress for export
                        self.transcriptionProgress = p.fraction * 0.3
                    }
                }
                print("[Transcribe] Temp export done: \(tempURL.lastPathComponent)")

                // Step 2: Transcribe via ModelManager (model stays cached between calls)
                transcriptionPhase = "Транскрибация..."
                subtitleEntries = try await TranscriptionService.transcribe(
                    url: tempURL,
                    modelManager: modelManager
                ) { progress in
                    Task { @MainActor in
                        // 30-100% progress for transcription
                        self.transcriptionProgress = 0.3 + progress.fraction * 0.7
                        self.transcriptionPhase = progress.phase.rawValue
                        self.transcriptionDetail = progress.detail ?? ""
                    }
                }
                statusMessage = "\(subtitleEntries.count) сегментов субтитров"
                print("[Transcribe] Done: \(subtitleEntries.count) segments — timings match timeline directly")
            } catch {
                statusMessage = "Ошибка транскрибации: \(error.localizedDescription)"
                print("[Transcribe] Error: \(error)")
            }
            isTranscribing = false
        }
    }

    /// Re-split words when user edits subtitle text
    public func updateSubtitleWords(at index: Int) {
        guard index < subtitleEntries.count else { return }
        let entry = subtitleEntries[index]
        let words = entry.text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }

        // Distribute time evenly across new words
        let start = CMTimeGetSeconds(entry.startTime)
        let end = CMTimeGetSeconds(entry.endTime)
        let perWord = (end - start) / Double(words.count)

        subtitleEntries[index].words = words.enumerated().map { i, word in
            RECore.WordTiming(
                word: word,
                startTime: CMTime(seconds: start + Double(i) * perWord, preferredTimescale: 600),
                endTime: CMTime(seconds: start + Double(i + 1) * perWord, preferredTimescale: 600)
            )
        }
    }

    /// Find active subtitle at current playhead position
    public func activeSubtitle(at playheadTime: CMTime) -> SubtitleEntry? {
        // Subtitles are in TIMELINE time (transcribed from exported video)
        // No source→timeline mapping needed
        return subtitleEntries.first { entry in
            CMTimeCompare(playheadTime, entry.startTime) >= 0 &&
            CMTimeCompare(playheadTime, entry.endTime) < 0
        }
    }

    /// Find active word index in a subtitle entry for karaoke
    public func activeWordIndex(in entry: SubtitleEntry, at playheadTime: CMTime) -> Int? {
        // Word timings are in TIMELINE time
        return entry.words.firstIndex { word in
            CMTimeCompare(playheadTime, word.startTime) >= 0 &&
            CMTimeCompare(playheadTime, word.endTime) < 0
        }
    }

    // MARK: - Export

    /// URL of last exported file (iOS uses this to present share sheet)
    public var lastExportedURL: URL?
    public var showShareSheet = false

    #if os(macOS)
    public func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name)_edited.mp4"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performExport(to: url)
    }
    #endif

    #if os(iOS)
    public func exportVideo() {
        // Clean all old temp files before new export
        Self.cleanupTempFiles()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(project.name)_edited.mp4")
        try? FileManager.default.removeItem(at: url)
        performExport(to: url)
    }
    #endif

    private func performExport(to url: URL) {
        isExporting = true
        exportProgress = 0

        let subs = showSubtitles ? subtitleEntries : []
        let style = subtitleStyle
        let splitEnabled = autoSplitEnabled
        let splitDur = autoSplitDuration

        Task { @MainActor in
            do {
                if splitEnabled && splitDur > 0 {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("silencecut_full_\(UUID().uuidString).mp4")
                    try await ExportService.export(
                        timeline: timeline,
                        to: tempURL,
                        preset: exportPreset,
                        subtitleEntries: subs,
                        subtitleStyle: style
                    ) { progress in
                        self.exportProgress = progress.fraction * 0.5
                    }

                    let asset = AVURLAsset(url: tempURL)
                    let totalDur = CMTimeGetSeconds(try await asset.load(.duration))
                    let numParts = Int(ceil(totalDur / splitDur))
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let dir = url.deletingLastPathComponent()

                    for i in 0..<numParts {
                        let partStart = Double(i) * splitDur
                        let partDur = min(splitDur, totalDur - partStart)
                        let partName = "\(baseName)_\(String(format: "%03d", i + 1)).mp4"
                        let partURL = dir.appendingPathComponent(partName)
                        try? FileManager.default.removeItem(at: partURL)

                        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { continue }
                        session.outputURL = partURL
                        session.outputFileType = .mp4
                        session.timeRange = CMTimeRange(
                            start: CMTime(seconds: partStart, preferredTimescale: 600),
                            duration: CMTime(seconds: partDur, preferredTimescale: 600)
                        )
                        await session.export()
                        statusMessage = "Нарезка \(i + 1)/\(numParts)..."
                        exportProgress = 0.5 + (Double(i + 1) / Double(numParts)) * 0.5
                    }

                    try? FileManager.default.removeItem(at: tempURL)
                    statusMessage = "Экспорт завершён! \(numParts) клипов"
                    #if os(macOS)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                    #elseif os(iOS)
                    lastExportedURL = dir
                    showShareSheet = true
                    #endif
                } else {
                    try await ExportService.export(
                        timeline: timeline,
                        to: url,
                        preset: exportPreset,
                        subtitleEntries: subs,
                        subtitleStyle: style
                    ) { progress in
                        self.exportProgress = progress.fraction
                    }
                    statusMessage = "Экспорт завершён!"
                    #if os(macOS)
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    #elseif os(iOS)
                    lastExportedURL = url
                    showShareSheet = true
                    #endif
                }
            } catch {
                statusMessage = "Ошибка экспорта: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    // MARK: - Navigation

    public func nudgePlayhead(by seconds: Double) {
        let current = CMTimeGetSeconds(playheadPosition)
        let maxDur = CMTimeGetSeconds(timeline.duration)
        let newTime = max(0, min(current + seconds, maxDur))
        let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
        seekSmoothly(to: cmTime)
    }

    // MARK: - Zoom

    public func zoomIn() {
        pixelsPerSecond = min(500, pixelsPerSecond * 1.25)
    }

    public func zoomOut() {
        pixelsPerSecond = max(20, pixelsPerSecond * 0.8)
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.isPlaying, !self.isSeeking else { return }
            self.playheadPosition = time
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
}
