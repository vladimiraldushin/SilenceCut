import SwiftUI
import AVFoundation
import RECore
import RETimeline
import REAudioAnalysis

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

        guard timeline.enabledClipCount > 0 else { return }

        do {
            let result = try await CompositionBuilder.build(from: timeline)
            let playerItem = AVPlayerItem(asset: result.composition)
            // Apply video composition for correct orientation (iPhone portrait)
            if let videoComp = result.videoComposition {
                playerItem.videoComposition = videoComp
            }
            // Apply audio crossfade for smooth transitions
            if let audioMix = result.audioMix {
                playerItem.audioMix = audioMix
            }
            player = AVPlayer(playerItem: playerItem)

            // Clamp currentTime to new duration
            let maxTime = timeline.duration
            let seekTime = CMTimeCompare(currentTime, maxTime) > 0 ? maxTime : currentTime
            await player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            playheadPosition = seekTime

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
        timeline.splitClip(at: idx, splitTime: playheadPosition)
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteClip(id: UUID) {
        timeline.deleteClip(id: id)
        if selectedClipId == id { selectedClipId = nil }
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteSelectedClip() {
        guard let id = selectedClipId else { return }
        deleteClip(id: id)
    }

    public func toggleClip(id: UUID) {
        timeline.toggleClip(id: id)
        Task { @MainActor in await rebuildPreview() }
    }

    public func trimClip(id: UUID, newSourceRange: CMTimeRange) {
        timeline.trimClip(id: id, newSourceRange: newSourceRange)
        debouncedRebuild()
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
