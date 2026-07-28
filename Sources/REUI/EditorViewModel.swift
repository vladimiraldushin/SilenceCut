import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import PhotosUI
import Photos
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

    // Silence review mode — zones over the timeline before applying cuts
    public struct SilenceReviewZone: Identifiable, Equatable {
        public let id: UUID
        public let sourceRange: CMTimeRange
        public var willCut: Bool
    }
    public var silenceReviewActive = false
    public var reviewZones: [SilenceReviewZone] = []
    public var skipSilencesInPreview = false
    /// RMS cache — instant re-detection when settings change (no file re-read)
    private var audioRMSCache: RMSCache?

    // Source video metadata
    public var videoFPS: Double = 30
    private var sourceDuration: CMTime = .zero

    // Video aspect ratio (9:16 for vertical, 16:9 for horizontal)
    public var videoAspectRatio: CGFloat = 9.0 / 16.0

    // Render options — framing, jump-cut zoom, loudness gain (preview + export share these)
    public var renderOptions: RenderOptions = .default {
        didSet {
            guard oldValue != renderOptions else { return }
            scheduleAutosave()
            // Aspect and zoom change the picture — rebuild so the preview matches the export
            if oldValue.outputAspect != renderOptions.outputAspect
                || oldValue.jumpCutZoomEnabled != renderOptions.jumpCutZoomEnabled
                || oldValue.jumpCutZoomAmount != renderOptions.jumpCutZoomAmount
                || oldValue.audioGain != renderOptions.audioGain {
                Task { @MainActor in await rebuildPreview() }
            }
        }
    }

    /// Aspect ratio for the preview frame — follows the chosen output format
    public var displayAspectRatio: CGFloat {
        renderOptions.outputAspect.ratio ?? videoAspectRatio
    }

    // Loudness normalization (BS.1770 / EBU R128)
    public var normalizeLoudness = false
    public var targetLUFS: Double = -14
    public var loudnessMeasurement: LoudnessMeasurement?
    public var isMeasuringLoudness = false
    public var loudnessProgress: Double = 0

    // Subtitles
    public var subtitleEntries: [SubtitleEntry] = []
    public var subtitleStyle: SubtitleStyle = .classic {
        didSet { scheduleAutosave() }
    }
    public var isTranscribing = false
    public var transcriptionProgress: Double = 0
    public var transcriptionPhase: String = ""
    public var transcriptionDetail: String = ""
    public var showSubtitles = true
    public var showSafeZones = false

    /// True while a subtitle text field has keyboard focus —
    /// hotkeys (space, delete, JKL) must not fire during text editing
    public var isTextEditingActive = false

    /// Hotkey cheatsheet overlay
    public var showHotkeysHelp = false

    // Auto-split export
    public var autoSplitEnabled = false
    public var autoSplitDuration: Double = 60  // seconds

    // Export
    public var isExporting = false
    public var exportProgress: Double = 0
    public var exportPreset: ExportPreset = .high

    // Undo/Redo (Memento — snapshot of EditTimeline + subtitles)
    private struct EditSnapshot {
        let timeline: EditTimeline
        let subtitles: [SubtitleEntry]
    }
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private var timeObserver: Any?

    // Smooth scrubbing state
    private var isSeekInProgress = false
    private var chaseTime: CMTime = .zero

    // ASR model manager (cached between transcriptions, shared lifecycle)
    public let modelManager = ModelManager()

    /// Пакетная обработка — живёт рядом с редактором, состояние сохраняется между открытиями панели
    public let batchQueue = BatchQueueModel()

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

    /// URL we hold security-scoped access to (balanced stop on next import)
    private var securityScopedURL: URL?

    public func importVideo(url: URL) {
        if let old = securityScopedURL {
            old.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        project.sourceURL = url
        project.name = url.deletingPathExtension().lastPathComponent

        // Reset state from previous project
        subtitleEntries = []
        silenceResult = nil
        silenceReviewActive = false
        reviewZones = []
        audioRMSCache = nil
        loudnessMeasurement = nil
        normalizeLoudness = false
        renderOptions = .default
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
                sourceDuration = duration

                // Detect video aspect ratio (9:16 vertical, 16:9 horizontal) + fps
                if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await videoTrack.load(.naturalSize)
                    let transform = try await videoTrack.load(.preferredTransform)
                    let transformed = size.applying(transform)
                    let w = abs(transformed.width)
                    let h = abs(transformed.height)
                    if h > 0 { videoAspectRatio = w / h }
                    let fps = try await videoTrack.load(.nominalFrameRate)
                    if fps > 1 { videoFPS = Double(fps) }
                }

                let availableRange = CMTimeRange(start: .zero, duration: duration)

                let clip = TimelineClip(
                    sourceURL: url,
                    availableRange: availableRange,
                    sourceRange: availableRange
                )
                timeline = EditTimeline(clips: [clip])

                // Restore autosaved project (sidecar .silencecut next to the video)
                if let snapshot = ProjectStore.load(for: url) {
                    timeline = snapshot.timeline
                    subtitleEntries = snapshot.subtitleEntries
                    subtitleStyle = snapshot.subtitleStyle
                    if let options = snapshot.renderOptions {
                        renderOptions = options
                        normalizeLoudness = abs(options.audioGain - 1.0) > 0.001
                    }
                    statusMessage = "Проект восстановлен: \(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))"
                } else {
                    statusMessage = "Загружено: \(url.lastPathComponent)"
                }
                await rebuildPreview()

                // Waveform + RMS cache in ONE streaming pass
                let analysis = try await AudioAnalysis.analyze(url: url)
                waveformData = analysis.waveform
                audioRMSCache = analysis.rms
                isImporting = false
            } catch {
                statusMessage = "Ошибка: \(error.localizedDescription)"
                isImporting = false
            }
        }
    }

    /// Open a .silencecut project file — derives the video path and imports it
    /// (the sidecar next to the video is restored automatically)
    public func openProjectFile(url: URL) {
        let videoURL = url.deletingPathExtension()
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            statusMessage = "Видео рядом с проектом не найдено: \(videoURL.lastPathComponent)"
            return
        }
        importVideo(url: videoURL)
    }

    // MARK: - Preview Rebuild (debounced)

    private var rebuildTask: Task<Void, Never>?

    @MainActor
    public func rebuildPreview() async {
        let currentTime = player?.currentTime() ?? .zero

        player?.pause()
        isPlaying = false

        guard timeline.enabledClipCount > 0 else {
            removeTimeObserver()
            player = nil
            playheadPosition = .zero
            return
        }

        do {
            let result = try await CompositionBuilder.build(from: timeline, options: renderOptions)
            let playerItem = AVPlayerItem(asset: result.composition)
            if let videoComp = result.videoComposition {
                playerItem.videoComposition = videoComp
            }
            if let audioMix = result.audioMix {
                playerItem.audioMix = audioMix
            }

            // Reuse the player — swapping the item avoids the black flash
            // a fresh AVPlayer causes in the preview view
            if let player {
                player.replaceCurrentItem(with: playerItem)
            } else {
                player = AVPlayer(playerItem: playerItem)
                setupTimeObserver()
            }

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

    public func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            playheadPosition = player.currentTime()
            isPlaying = false
            print("[Playback] Paused at \(CMTimeGetSeconds(playheadPosition))s")
        } else {
            // Seek to playheadPosition, wait for completion, then play.
            // Cancel any in-flight chase-seek first.
            let target = playheadPosition
            isSeekInProgress = false  // reset chase-seek state
            print("[Playback] Play requested at \(CMTimeGetSeconds(target))s")

            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard let self else { return }
                Task { @MainActor in
                    guard finished else { return }
                    self.isPlaying = true
                    self.player?.play()
                    print("[Playback] Playing from \(CMTimeGetSeconds(target))s")
                }
            }
        }
    }

    // MARK: - Seek (unified)

    /// Seek to a specific time. Updates playheadPosition immediately (visual),
    /// then seeks the player (audio/video). Works when playing or paused.
    public func seekSmoothly(to time: CMTime) {
        // 1. Update visual position immediately
        playheadPosition = time

        // 2. If playing, pause first — user is repositioning
        if isPlaying {
            player?.pause()
            isPlaying = false
        }

        // 3. Chase-seek the player to match
        chaseTime = time
        if !isSeekInProgress {
            performChaseSeek()
        }
    }

    private func performChaseSeek() {
        guard let player else { return }
        isSeekInProgress = true
        let target = chaseTime
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            if self.chaseTime != target {
                // User moved again during seek — chase the new position
                self.performChaseSeek()
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

    /// I — ripple trim: cut everything left of the playhead within the current clip
    public func trimInAtPlayhead() {
        guard let idx = timeline.clipIndex(at: playheadPosition) else { return }
        let clip = timeline.clips[idx]
        guard let sourceAtPlayhead = timeline.sourceTime(forTimelineTime: playheadPosition) else { return }
        saveUndoState()
        invalidateSubtitles()
        let end = CMTimeRangeGetEnd(clip.sourceRange)
        timeline.trimClip(id: clip.id, newSourceRange: CMTimeRange(
            start: sourceAtPlayhead,
            duration: CMTimeSubtract(end, sourceAtPlayhead)
        ))
        Task { @MainActor in await rebuildPreview() }
    }

    /// O — ripple trim: cut everything right of the playhead within the current clip
    public func trimOutAtPlayhead() {
        guard let idx = timeline.clipIndex(at: playheadPosition) else { return }
        let clip = timeline.clips[idx]
        guard let sourceAtPlayhead = timeline.sourceTime(forTimelineTime: playheadPosition) else { return }
        saveUndoState()
        invalidateSubtitles()
        timeline.trimClip(id: clip.id, newSourceRange: CMTimeRange(
            start: clip.sourceRange.start,
            duration: CMTimeSubtract(sourceAtPlayhead, clip.sourceRange.start)
        ))
        Task { @MainActor in await rebuildPreview() }
    }

    // MARK: - Cut Navigation

    /// Timeline seconds of every cut boundary (clip starts + end of timeline)
    private var cutBoundaries: [Double] {
        var points = timeline.clips.filter(\.isEnabled).map { CMTimeGetSeconds($0.timelineOffset) }
        points.append(CMTimeGetSeconds(timeline.duration))
        return points.sorted()
    }

    public func jumpToPreviousCut() {
        let current = CMTimeGetSeconds(playheadPosition)
        guard let prev = cutBoundaries.last(where: { $0 < current - 0.02 }) else { return }
        seekSmoothly(to: CMTime(seconds: prev, preferredTimescale: 600))
    }

    public func jumpToNextCut() {
        let current = CMTimeGetSeconds(playheadPosition)
        guard let next = cutBoundaries.first(where: { $0 > current + 0.02 }) else { return }
        seekSmoothly(to: CMTime(seconds: next, preferredTimescale: 600))
    }

    // MARK: - Subtitle Segment Editing

    /// Merge subtitle segment with the following one
    public func mergeSubtitleWithNext(at index: Int) {
        guard index >= 0, index + 1 < subtitleEntries.count else { return }
        var first = subtitleEntries[index]
        let second = subtitleEntries[index + 1]
        first.text = first.text + " " + second.text
        first.endTime = second.endTime
        first.words = first.words + second.words
        subtitleEntries[index] = first
        subtitleEntries.remove(at: index + 1)
        scheduleAutosave()
    }

    /// Split subtitle segment at the current playhead position
    public func splitSubtitleAtPlayhead(index: Int) {
        guard index >= 0, index < subtitleEntries.count else { return }
        let entry = subtitleEntries[index]
        let t = playheadPosition
        guard CMTimeCompare(t, entry.startTime) > 0, CMTimeCompare(t, entry.endTime) < 0 else {
            statusMessage = "Поставьте плейхед внутрь сегмента"
            return
        }

        let tSec = CMTimeGetSeconds(t)
        var firstWords = entry.words.filter { CMTimeGetSeconds($0.startTime) < tSec }
        var secondWords = entry.words.filter { CMTimeGetSeconds($0.startTime) >= tSec }

        // No word timings — split the text list proportionally by time
        if entry.words.isEmpty {
            let allWords = entry.text.split(separator: " ").map(String.init)
            guard allWords.count >= 2 else { return }
            let fraction = (tSec - CMTimeGetSeconds(entry.startTime)) / CMTimeGetSeconds(entry.duration)
            let splitIdx = min(max(1, Int(Double(allWords.count) * fraction)), allWords.count - 1)
            firstWords = []
            secondWords = []
            let first = SubtitleEntry(text: allWords[..<splitIdx].joined(separator: " "),
                                      startTime: entry.startTime, endTime: t)
            let second = SubtitleEntry(text: allWords[splitIdx...].joined(separator: " "),
                                       startTime: t, endTime: entry.endTime)
            subtitleEntries[index] = first
            subtitleEntries.insert(second, at: index + 1)
            updateSubtitleWords(at: index)
            updateSubtitleWords(at: index + 1)
            scheduleAutosave()
            return
        }

        guard !firstWords.isEmpty, !secondWords.isEmpty else {
            statusMessage = "Плейхед слишком близко к краю сегмента"
            return
        }
        // Snap the boundary to the word gap
        firstWords[firstWords.count - 1].endTime = min(firstWords[firstWords.count - 1].endTime, t)
        secondWords[0].startTime = max(secondWords[0].startTime, t)

        let first = SubtitleEntry(
            text: firstWords.map(\.word).joined(separator: " "),
            startTime: entry.startTime, endTime: t, words: firstWords
        )
        let second = SubtitleEntry(
            text: secondWords.map(\.word).joined(separator: " "),
            startTime: t, endTime: entry.endTime, words: secondWords
        )
        subtitleEntries[index] = first
        subtitleEntries.insert(second, at: index + 1)
        scheduleAutosave()
    }

    // MARK: - Undo/Redo

    private func saveUndoState() {
        undoStack.append(EditSnapshot(timeline: timeline, subtitles: subtitleEntries))
        redoStack.removeAll()
        // Limit stack depth
        if undoStack.count > 50 { undoStack.removeFirst() }
        scheduleAutosave()
    }

    // MARK: - Project Autosave (.silencecut sidecar next to the video)

    private var autosaveTask: Task<Void, Never>?
    public private(set) var lastAutosaveAt: Date?

    /// Debounced autosave — called after every meaningful edit
    public func scheduleAutosave() {
        guard project.sourceURL != nil else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveProjectNow()
        }
    }

    public func saveProjectNow() {
        guard let url = project.sourceURL else { return }
        let snapshot = ProjectSnapshot(
            name: project.name,
            timeline: timeline,
            subtitleEntries: subtitleEntries,
            subtitleStyle: subtitleStyle,
            renderOptions: renderOptions
        )
        do {
            try ProjectStore.save(snapshot, for: url)
            lastAutosaveAt = Date()
        } catch {
            print("[Autosave] Failed: \(error)")
        }
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(EditSnapshot(timeline: timeline, subtitles: subtitleEntries))
        timeline = previous.timeline
        subtitleEntries = previous.subtitles
        scheduleAutosave()
        Task { @MainActor in await rebuildPreview() }
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditSnapshot(timeline: timeline, subtitles: subtitleEntries))
        timeline = next.timeline
        subtitleEntries = next.subtitles
        scheduleAutosave()
        Task { @MainActor in await rebuildPreview() }
    }

    // MARK: - Silence Detection (review mode)

    /// Ensure the RMS cache exists (built during import; falls back to a fresh pass)
    @MainActor
    private func ensureRMSCache() async throws -> RMSCache {
        if let cache = audioRMSCache { return cache }
        guard let url = project.sourceURL else { throw SilenceDetector.DetectionError.cannotRead }
        isDetectingSilence = true
        defer { isDetectingSilence = false }
        let analysis = try await AudioAnalysis.analyze(url: url) { progress in
            Task { @MainActor in self.detectionProgress = progress }
        }
        waveformData = analysis.waveform
        audioRMSCache = analysis.rms
        return analysis.rms
    }

    /// «Найти паузы» — detect and show zones for review; the timeline is untouched
    /// until the user hits «Применить»
    public func enterSilenceReview() {
        guard project.sourceURL != nil else { return }
        Task { @MainActor in
            do {
                let cache = try await ensureRMSCache()
                let result = SilenceDetector.detect(cache: cache, settings: silenceSettings)
                silenceResult = result
                reviewZones = result.silenceRanges.map {
                    SilenceReviewZone(id: UUID(), sourceRange: $0, willCut: true)
                }
                silenceReviewActive = true
                statusMessage = "Пауз: \(reviewZones.count) — клик по зоне переключает вырезать/оставить"
            } catch {
                statusMessage = "Ошибка анализа: \(error.localizedDescription)"
            }
        }
    }

    /// Instant re-detection from the cache when settings sliders move (review mode only)
    public func recomputeReviewZones() {
        guard silenceReviewActive, let cache = audioRMSCache else { return }
        let result = SilenceDetector.detect(cache: cache, settings: silenceSettings)
        silenceResult = result
        reviewZones = result.silenceRanges.map {
            SilenceReviewZone(id: UUID(), sourceRange: $0, willCut: true)
        }
    }

    public func toggleReviewZone(id: UUID) {
        guard let idx = reviewZones.firstIndex(where: { $0.id == id }) else { return }
        reviewZones[idx].willCut.toggle()
    }

    /// Zones mapped to timeline seconds for TimelineView display
    public var displayZones: [TimelineSilenceZone] {
        guard silenceReviewActive else { return [] }
        return reviewZones.compactMap { zone in
            guard let start = timeline.timelineTime(forSourceTime: zone.sourceRange.start) else { return nil }
            let zoneEnd = CMTimeRangeGetEnd(zone.sourceRange)
            // End of a trailing zone maps outside clips — clamp to timeline end
            let end = timeline.timelineTime(forSourceTime: zoneEnd) ?? timeline.duration
            let s = CMTimeGetSeconds(start)
            let e = CMTimeGetSeconds(end)
            guard e > s else { return nil }
            return TimelineSilenceZone(id: zone.id, startSeconds: s, endSeconds: e, willCut: zone.willCut)
        }
    }

    /// Apply the review: cut all zones marked willCut
    public func applySilenceReview() {
        guard silenceReviewActive, let sourceURL = project.sourceURL else { return }
        let cutZones = reviewZones.filter(\.willCut).sorted {
            CMTimeCompare($0.sourceRange.start, $1.sourceRange.start) < 0
        }
        guard !cutZones.isEmpty else {
            cancelSilenceReview()
            return
        }

        // Speech ranges = complement of cut zones over the source duration
        let total = CMTimeGetSeconds(sourceDuration)
        var speechRanges: [CMTimeRange] = []
        var cursor = 0.0
        for zone in cutZones {
            let zStart = CMTimeGetSeconds(zone.sourceRange.start)
            let zEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(zone.sourceRange))
            if zStart > cursor + 0.01 {
                speechRanges.append(CMTimeRange(
                    start: CMTime(seconds: cursor, preferredTimescale: 600),
                    duration: CMTime(seconds: zStart - cursor, preferredTimescale: 600)
                ))
            }
            cursor = max(cursor, zEnd)
        }
        if cursor < total - 0.01 {
            speechRanges.append(CMTimeRange(
                start: CMTime(seconds: cursor, preferredTimescale: 600),
                duration: CMTime(seconds: total - cursor, preferredTimescale: 600)
            ))
        }

        saveUndoState()
        invalidateSubtitles()
        timeline = EditTimeline.fromSpeechRanges(
            speechRanges,
            sourceURL: sourceURL,
            availableRange: CMTimeRange(start: .zero, duration: sourceDuration)
        )
        let removed = cutZones.reduce(0.0) { $0 + CMTimeGetSeconds($1.sourceRange.duration) }
        silenceReviewActive = false
        reviewZones = []
        skipSilencesInPreview = false
        Task { @MainActor in await rebuildPreview() }
        statusMessage = "Вырезано пауз: \(cutZones.count), −\(String(format: "%.1f", removed)) с"
    }

    public func cancelSilenceReview() {
        silenceReviewActive = false
        reviewZones = []
        skipSilencesInPreview = false
        statusMessage = ""
    }

    /// Restore original (single clip, full video)
    public func restoreOriginal() {
        guard let url = project.sourceURL else { return }
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
                saveUndoState()
                invalidateSubtitles()
                timeline = EditTimeline(clips: [clip])
                silenceResult = nil
                await rebuildPreview()
                statusMessage = "Оригинал восстановлен"
            } catch {
                statusMessage = "Ошибка восстановления: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Loudness Normalization (BS.1770 / EBU R128)

    /// Измеряет громкость исходника и выставляет гейн до целевой LUFS.
    /// Замер идёт по исходному файлу: гейтинг BS.1770 и так игнорирует паузы,
    /// поэтому вырезание тишины на результат практически не влияет.
    public func applyLoudnessNormalization() {
        guard normalizeLoudness else {
            renderOptions.audioGain = 1.0
            return
        }
        guard let url = project.sourceURL else { return }

        // Уже измеряли этот файл — просто пересчитываем гейн под текущую цель
        if let measurement = loudnessMeasurement {
            setGain(from: measurement)
            return
        }

        isMeasuringLoudness = true
        loudnessProgress = 0
        Task { @MainActor in
            do {
                let measurement = try await LoudnessAnalyzer.measure(url: url) { progress in
                    Task { @MainActor in self.loudnessProgress = progress }
                }
                loudnessMeasurement = measurement
                setGain(from: measurement)
            } catch {
                statusMessage = "Ошибка замера громкости: \(error.localizedDescription)"
                normalizeLoudness = false
            }
            isMeasuringLoudness = false
        }
    }

    private func setGain(from measurement: LoudnessMeasurement) {
        let gain = LoudnessAnalyzer.gain(for: measurement, targetLUFS: targetLUFS)
        renderOptions.audioGain = gain
        let db = 20 * log10(max(gain, 0.0001))
        statusMessage = String(
            format: "Громкость: %.1f LUFS → %.0f LUFS (%+.1f дБ)",
            measurement.integratedLUFS, targetLUFS, db
        )
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
        transcriptionPhase = "Экспорт аудио..."
        transcriptionDetail = ""

        // Clean up old temp files before creating new ones
        Self.cleanupTempFiles()

        Task { @MainActor in
            do {
                // Step 1: Export timeline AUDIO to temp file — much faster than a full
                // video encode, timings still match the timeline exactly
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("silencecut_transcribe_\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: tempURL) }

                try await ExportService.exportAudioOnly(
                    timeline: timeline,
                    to: tempURL
                ) { p in
                    Task { @MainActor in
                        // 0-30% progress for export
                        self.transcriptionProgress = p.fraction * 0.3
                    }
                }
                print("[Transcribe] Temp audio export done: \(tempURL.lastPathComponent)")

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
        scheduleAutosave()
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
    public var lastExportedMarkdownURL: URL?
    public var lastExportedSRTURL: URL?
    public var showShareSheet = false

    /// Active export cancellation token
    private var exportCancellation: ExportCancellationToken?
    public var exportRemainingText = ""

    public func cancelExport() {
        exportCancellation?.cancel()
        statusMessage = "Отмена экспорта..."
    }

    /// Save transcript files (.md + .srt) next to the exported video (timings match timeline)
    private func writeSubtitleMarkdown(next to: URL) {
        lastExportedMarkdownURL = nil
        lastExportedSRTURL = nil
        guard !subtitleEntries.isEmpty else { return }
        do {
            let mdURL = try SubtitleMarkdownExporter.write(
                entries: subtitleEntries,
                videoURL: to,
                projectName: project.name
            )
            lastExportedMarkdownURL = mdURL
            let srtURL = try SubtitleSRTExporter.writeSRT(entries: subtitleEntries, videoURL: to)
            lastExportedSRTURL = srtURL
            print("[Export] Subtitle files saved: \(mdURL.lastPathComponent), \(srtURL.lastPathComponent)")
        } catch {
            print("[Export] Subtitle files failed: \(error)")
        }
    }

    /// Формат «≈ 1:23 осталось» для прогресса экспорта
    static func remainingText(_ progress: ExportProgress) -> String {
        guard let remaining = progress.estimatedRemaining, remaining.isFinite, remaining > 1 else { return "" }
        let total = Int(remaining.rounded())
        return String(format: "≈ %d:%02d осталось", total / 60, total % 60)
    }

    #if os(macOS)
    public func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name)_edited.mp4"
        panel.canCreateDirectories = true

        // Export options live in the save dialog (preset, auto-split, subtitles)
        let accessory = NSHostingView(rootView: ExportOptionsView(viewModel: self))
        accessory.frame = NSRect(x: 0, y: 0, width: 380, height: accessory.fittingSize.height)
        panel.accessoryView = accessory

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

    /// Файлы для share sheet: видео (или все части нарезки) + .md/.srt
    public var exportedShareItems: [URL] {
        guard let url = lastExportedURL else { return [] }
        var items: [URL] = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let parts = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            items = parts.filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            items = [url]
        }
        if let md = lastExportedMarkdownURL { items.append(md) }
        if let srt = lastExportedSRTURL { items.append(srt) }
        return items
    }

    /// Сохранить экспортированные видео в Фото (все части при нарезке)
    public func saveExportToPhotos() {
        let videos = exportedShareItems.filter { $0.pathExtension == "mp4" }
        guard !videos.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self.statusMessage = "Нет доступа к Фото" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for video in videos {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
                }
            }) { success, error in
                Task { @MainActor in
                    self.statusMessage = success
                        ? "Сохранено в Фото: \(videos.count) видео"
                        : "Ошибка сохранения в Фото: \(error?.localizedDescription ?? "")"
                }
            }
        }
    }
    #endif

    private func performExport(to url: URL) {
        isExporting = true
        exportProgress = 0
        exportRemainingText = ""

        let subs = showSubtitles ? subtitleEntries : []
        let style = subtitleStyle
        let splitEnabled = autoSplitEnabled
        let splitDur = autoSplitDuration
        let token = ExportCancellationToken()
        exportCancellation = token

        Task { @MainActor in
            do {
                if splitEnabled && splitDur > 0 {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("silencecut_full_\(UUID().uuidString).mp4")
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    try await ExportService.export(
                        timeline: timeline,
                        to: tempURL,
                        preset: exportPreset,
                        subtitleEntries: subs,
                        subtitleStyle: style,
                        renderOptions: renderOptions,
                        cancellation: token
                    ) { progress in
                        self.exportProgress = progress.fraction * 0.5
                        self.exportRemainingText = Self.remainingText(progress)
                    }

                    let asset = AVURLAsset(url: tempURL)
                    let totalDur = CMTimeGetSeconds(try await asset.load(.duration))
                    let numParts = Int(ceil(totalDur / splitDur))
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let dir = url.deletingLastPathComponent()

                    for i in 0..<numParts {
                        if token.isCancelled { throw ExportService.ExportError.cancelled }
                        let partStart = Double(i) * splitDur
                        let partDur = min(splitDur, totalDur - partStart)
                        let partName = "\(baseName)_\(String(format: "%03d", i + 1)).mp4"
                        let partURL = dir.appendingPathComponent(partName)
                        try? FileManager.default.removeItem(at: partURL)

                        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                            throw ExportService.ExportError.exportFailed("Не удалось создать сессию для части \(i + 1)")
                        }
                        session.outputURL = partURL
                        session.outputFileType = .mp4
                        session.timeRange = CMTimeRange(
                            start: CMTime(seconds: partStart, preferredTimescale: 600),
                            duration: CMTime(seconds: partDur, preferredTimescale: 600)
                        )
                        await session.export()
                        guard session.status == .completed else {
                            throw ExportService.ExportError.exportFailed(
                                "Часть \(i + 1): \(session.error?.localizedDescription ?? "неизвестная ошибка")"
                            )
                        }
                        statusMessage = "Нарезка \(i + 1)/\(numParts)..."
                        exportProgress = 0.5 + (Double(i + 1) / Double(numParts)) * 0.5
                    }

                    writeSubtitleMarkdown(next: url)
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
                        subtitleStyle: style,
                        renderOptions: renderOptions,
                        cancellation: token
                    ) { progress in
                        self.exportProgress = progress.fraction
                        self.exportRemainingText = Self.remainingText(progress)
                    }
                    writeSubtitleMarkdown(next: url)
                    statusMessage = "Экспорт завершён!"
                    #if os(macOS)
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    #elseif os(iOS)
                    lastExportedURL = url
                    showShareSheet = true
                    #endif
                }
            } catch ExportService.ExportError.cancelled {
                statusMessage = "Экспорт отменён"
            } catch {
                statusMessage = "Ошибка экспорта: \(error.localizedDescription)"
            }
            isExporting = false
            exportRemainingText = ""
            exportCancellation = nil
        }
    }

    // MARK: - Style Preview Export (5-second test)

    public var isPreviewExporting = false

    /// Export ~5 seconds around the playhead with burned-in subtitles —
    /// a fast way to check the subtitle style without a full export
    public func exportStylePreview() {
        guard timeline.enabledClipCount > 0 else { return }
        let duration = CMTimeGetSeconds(timeline.duration)
        let t0 = min(max(0, CMTimeGetSeconds(playheadPosition) - 2.5), max(0, duration - 5))
        let t1 = min(duration, t0 + 5)
        guard t1 > t0 + 0.2 else { return }

        // Slice the timeline to [t0, t1] (timeline coords → source subranges, speed-aware)
        var sliced: [TimelineClip] = []
        for clip in timeline.clips where clip.isEnabled {
            let clipStart = CMTimeGetSeconds(clip.timelineOffset)
            let clipEnd = CMTimeGetSeconds(clip.timelineEnd)
            let overlapStart = max(clipStart, t0)
            let overlapEnd = min(clipEnd, t1)
            guard overlapEnd > overlapStart else { continue }
            let sourceStart = CMTimeGetSeconds(clip.sourceRange.start) + (overlapStart - clipStart) * clip.speed
            let sourceDur = (overlapEnd - overlapStart) * clip.speed
            sliced.append(TimelineClip(
                sourceURL: clip.sourceURL,
                availableRange: clip.availableRange,
                sourceRange: CMTimeRange(
                    start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: sourceDur, preferredTimescale: 600)
                ),
                speed: clip.speed
            ))
        }
        var previewTimeline = EditTimeline(clips: sliced)
        previewTimeline.recalculateOffsets()

        // Shift subtitles into the window's local time
        let shiftedSubs: [SubtitleEntry] = subtitleEntries.compactMap { entry in
            let s = CMTimeGetSeconds(entry.startTime)
            let e = CMTimeGetSeconds(entry.endTime)
            guard e > t0, s < t1 else { return nil }
            let words = entry.words.map { w in
                RECore.WordTiming(
                    word: w.word,
                    startTime: CMTime(seconds: max(0, CMTimeGetSeconds(w.startTime) - t0), preferredTimescale: 600),
                    endTime: CMTime(seconds: max(0, CMTimeGetSeconds(w.endTime) - t0), preferredTimescale: 600)
                )
            }
            return SubtitleEntry(
                text: entry.text,
                startTime: CMTime(seconds: max(0, s - t0), preferredTimescale: 600),
                endTime: CMTime(seconds: max(0.1, e - t0), preferredTimescale: 600),
                words: words
            )
        }

        isPreviewExporting = true
        let style = subtitleStyle
        Task { @MainActor in
            do {
                let previewURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("silencecut_stylepreview_\(UUID().uuidString).mp4")
                try await ExportService.export(
                    timeline: previewTimeline,
                    to: previewURL,
                    preset: .medium,
                    subtitleEntries: shiftedSubs,
                    subtitleStyle: style,
                    renderOptions: renderOptions
                ) { _ in }
                statusMessage = "Тест стиля готов"
                #if os(macOS)
                NSWorkspace.shared.open(previewURL)
                #elseif os(iOS)
                lastExportedURL = previewURL
                showShareSheet = true
                #endif
            } catch {
                statusMessage = "Ошибка теста стиля: \(error.localizedDescription)"
            }
            isPreviewExporting = false
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
            guard let self, self.isPlaying else { return }
            self.playheadPosition = time

            // Review mode: «прослушать с пропусками» — jump over zones marked for cutting
            if self.silenceReviewActive, self.skipSilencesInPreview,
               let sourceTime = self.timeline.sourceTime(forTimelineTime: time) {
                let s = CMTimeGetSeconds(sourceTime)
                if let zone = self.reviewZones.first(where: { z in
                    z.willCut &&
                    s >= CMTimeGetSeconds(z.sourceRange.start) + 0.02 &&
                    s < CMTimeGetSeconds(CMTimeRangeGetEnd(z.sourceRange)) - 0.02
                }) {
                    let zoneEnd = CMTimeRangeGetEnd(zone.sourceRange)
                    let target = self.timeline.timelineTime(forSourceTime: zoneEnd) ?? self.timeline.duration
                    self.playheadPosition = target
                    self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
}
