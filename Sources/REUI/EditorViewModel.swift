import SwiftUI
import AVFoundation
import RECore
import RETimeline

/// Main editor view model — owns the timeline, player, and coordinates changes.
@Observable
public class EditorViewModel {
    public var project = Project()
    public var timeline = EditTimeline()
    public private(set) var player: AVPlayer?
    public var playheadPosition: CMTime = .zero
    public var isPlaying = false
    public var statusMessage = ""

    private var timeObserver: Any?

    public init() {}

    // MARK: - File Import

    public func importVideo(url: URL) {
        // Start security-scoped access
        _ = url.startAccessingSecurityScopedResource()

        project.sourceURL = url
        project.name = url.deletingPathExtension().lastPathComponent

        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let availableRange = CMTimeRange(start: .zero, duration: duration)

                // Create single clip spanning the entire video
                let clip = TimelineClip(
                    sourceURL: url,
                    availableRange: availableRange,
                    sourceRange: availableRange
                )
                timeline = EditTimeline(clips: [clip])

                statusMessage = "Loaded: \(url.lastPathComponent)"
                await rebuildPreview()
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Preview Rebuild

    /// Rebuild AVPlayer from scratch — the key pattern from the research
    @MainActor
    public func rebuildPreview() async {
        let currentTime = player?.currentTime() ?? .zero

        // Full dealloc to reset internal state
        removeTimeObserver()
        player?.pause()
        player = nil

        guard timeline.enabledClipCount > 0 else { return }

        do {
            let result = try await CompositionBuilder.build(from: timeline)
            let playerItem = AVPlayerItem(asset: result.composition)
            player = AVPlayer(playerItem: playerItem)

            // Restore playback position
            await player?.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)

            setupTimeObserver()
        } catch {
            statusMessage = "Preview error: \(error.localizedDescription)"
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

    public func seek(to time: CMTime) {
        playheadPosition = time
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Timeline Operations

    public func splitAtPlayhead() {
        guard let idx = timeline.clipIndex(at: playheadPosition) else { return }
        timeline.splitClip(at: idx, splitTime: playheadPosition)
        Task { @MainActor in await rebuildPreview() }
    }

    public func deleteClip(id: UUID) {
        timeline.deleteClip(id: id)
        Task { @MainActor in await rebuildPreview() }
    }

    public func toggleClip(id: UUID) {
        timeline.toggleClip(id: id)
        Task { @MainActor in await rebuildPreview() }
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
