import SwiftUI
import AppKit
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
    public var showSubtitles = true

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

    public init() {}

    // MARK: - File Import

    public func importVideo(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        project.sourceURL = url
        project.name = url.deletingPathExtension().lastPathComponent

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
                statusMessage = "Loaded: \(url.lastPathComponent)"
                await rebuildPreview()

                // Generate waveform
                waveformData = try await WaveformGenerator.generate(from: url)
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
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
            await player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            playheadPosition = seekTime
            isPlaying = false

            setupTimeObserver()
        } catch {
            statusMessage = "Preview error: \(error.localizedDescription)"
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
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    // MARK: - Smooth Scrubbing (chase-seek pattern)

    public func seekSmoothly(to time: CMTime) {
        playheadPosition = time
        chaseTime = time
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

    public func splitAtPlayhead() {
        guard let idx = timeline.clipIndex(at: playheadPosition) else { return }
        saveUndoState()
        timeline.splitClip(at: idx, splitTime: playheadPosition)
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteClip(id: UUID) {
        saveUndoState()
        timeline.deleteClip(id: id)
        if selectedClipId == id { selectedClipId = nil }
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteSelectedClip() {
        guard let id = selectedClipId else { return }
        deleteClip(id: id)
    }

    public func toggleClip(id: UUID) {
        saveUndoState()
        timeline.toggleClip(id: id)
        Task { @MainActor in await rebuildPreview() }
    }

    public func trimClip(id: UUID, newSourceRange: CMTimeRange) {
        saveUndoState()
        timeline.trimClip(id: id, newSourceRange: newSourceRange)
        debouncedRebuild()
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
                statusMessage = "\(result.pauseCount) pauses removed, saved \(String(format: "%.1f", result.totalSilenceDuration))s"
            } catch {
                statusMessage = "Detection error: \(error.localizedDescription)"
            }
            isDetectingSilence = false
        }
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
                timeline = EditTimeline(clips: [clip])
                silenceResult = nil
                await rebuildPreview()
                statusMessage = "Restored original"
            } catch {
                statusMessage = "Error restoring: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Transcription

    public func transcribe() {
        guard let url = project.sourceURL else { return }
        isTranscribing = true
        transcriptionProgress = 0

        Task { @MainActor in
            do {
                subtitleEntries = try await TranscriptionService.transcribe(
                    url: url,
                    language: "ru"
                ) { progress in
                    Task { @MainActor in
                        self.transcriptionProgress = progress.fraction
                        self.transcriptionPhase = progress.phase.rawValue
                    }
                }
                statusMessage = "\(subtitleEntries.count) subtitle segments"
            } catch {
                statusMessage = "Transcription error: \(error.localizedDescription)"
            }
            isTranscribing = false
        }
    }

    /// Find active subtitle at current playhead position
    public func activeSubtitle(at playheadTime: CMTime) -> SubtitleEntry? {
        // Map timeline time → source time
        guard let sourceTime = timeline.sourceTime(forTimelineTime: playheadTime) else { return nil }
        return subtitleEntries.first { entry in
            CMTimeCompare(sourceTime, entry.startTime) >= 0 &&
            CMTimeCompare(sourceTime, entry.endTime) < 0
        }
    }

    /// Find active word index in a subtitle entry for karaoke
    public func activeWordIndex(in entry: SubtitleEntry, at playheadTime: CMTime) -> Int? {
        guard let sourceTime = timeline.sourceTime(forTimelineTime: playheadTime) else { return nil }
        return entry.words.firstIndex { word in
            CMTimeCompare(sourceTime, word.startTime) >= 0 &&
            CMTimeCompare(sourceTime, word.endTime) < 0
        }
    }

    // MARK: - Export

    public func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name)_edited.mp4"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        exportProgress = 0

        Task { @MainActor in
            do {
                try await ExportService.export(
                    timeline: timeline,
                    to: url,
                    preset: exportPreset
                ) { progress in
                    self.exportProgress = progress.fraction
                }
                statusMessage = "Export complete!"
                // Reveal in Finder
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            } catch {
                statusMessage = "Export error: \(error.localizedDescription)"
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
            guard let self, self.isPlaying else { return }
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
