import Foundation
import AVFoundation

/// Exports the edited timeline to a video file using hardware-accelerated encoding
actor VideoExporter {

    enum ExportError: Error, LocalizedError {
        case noSource
        case compositionFailed(String)
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noSource: return "No source video"
            case .compositionFailed(let msg): return "Composition failed: \(msg)"
            case .exportFailed(let msg): return "Export failed: \(msg)"
            case .cancelled: return "Export was cancelled"
            }
        }
    }

    struct ExportProgress {
        let progress: Double  // 0.0 to 1.0
        let estimatedTimeRemaining: Double?
    }

    private var exportSession: AVAssetExportSession?

    func cancel() {
        exportSession?.cancelExport()
    }

    /// Export the timeline to a video file
    func export(
        sourceURL: URL,
        fragments: [TimelineFragment],
        settings: ExportSettings,
        outputURL: URL,
        progressHandler: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVAsset(url: sourceURL)

        // 1. Create composition with only included fragments
        let composition = AVMutableComposition()
        let includedFragments = fragments.filter { $0.isIncluded }

        guard !includedFragments.isEmpty else {
            throw ExportError.compositionFailed("No fragments to export")
        }

        // Add video track
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.compositionFailed("No video track in source")
        }

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionFailed("Cannot create video track")
        }

        // Add audio track
        let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let compositionAudioTrack: AVMutableCompositionTrack?
        if sourceAudioTrack != nil {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        } else {
            compositionAudioTrack = nil
        }

        // 2. Insert fragments into composition
        var currentTime = CMTime.zero

        for fragment in includedFragments {
            let timeRange = fragment.cmTimeRange

            do {
                try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: currentTime)

                if let audioTrack = sourceAudioTrack, let compAudio = compositionAudioTrack {
                    try compAudio.insertTimeRange(timeRange, of: audioTrack, at: currentTime)
                }

                currentTime = CMTimeAdd(currentTime, timeRange.duration)
            } catch {
                throw ExportError.compositionFailed("Failed to insert fragment: \(error.localizedDescription)")
            }
        }

        // 3. Configure export session
        let presetName = avPreset(for: settings)

        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError.exportFailed("Cannot create export session")
        }

        self.exportSession = session
        session.outputURL = outputURL
        session.outputFileType = avFileType(for: settings)
        session.shouldOptimizeForNetworkUse = true

        // 4. Export with progress monitoring
        let startTime = CFAbsoluteTimeGetCurrent()

        // Start progress monitoring
        let progressTask = Task {
            while !Task.isCancelled {
                let progress = Double(session.progress)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let estimatedTotal = progress > 0 ? elapsed / progress : nil
                let remaining = estimatedTotal.map { $0 - elapsed }

                progressHandler?(ExportProgress(
                    progress: progress,
                    estimatedTimeRemaining: remaining
                ))

                try await Task.sleep(for: .milliseconds(200))
            }
        }

        // Perform export
        await session.export()
        progressTask.cancel()

        switch session.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw ExportError.cancelled
        case .failed:
            throw ExportError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
        default:
            throw ExportError.exportFailed("Unexpected export status: \(session.status.rawValue)")
        }
    }

    private func avPreset(for settings: ExportSettings) -> String {
        switch settings.preset {
        case .original: return AVAssetExportPresetPassthrough
        case .high: return AVAssetExportPreset1920x1080
        case .medium: return AVAssetExportPreset1280x720
        case .low: return AVAssetExportPreset640x480
        }
    }

    private func avFileType(for settings: ExportSettings) -> AVFileType {
        switch settings.format {
        case .mp4: return .mp4
        case .hevc: return .mp4
        case .mov: return .mov
        }
    }
}
