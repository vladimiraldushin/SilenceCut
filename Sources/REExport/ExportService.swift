import Foundation
import AVFoundation
import CoreMedia
import RECore
import RETimeline

/// Export quality presets
public enum ExportPreset: String, CaseIterable, Identifiable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    public var id: String { rawValue }

    public var videoBitRate: Int {
        switch self {
        case .high: return 10_000_000    // 10 Mbps
        case .medium: return 5_000_000   // 5 Mbps
        case .low: return 2_500_000      // 2.5 Mbps
        }
    }

    public var audioBitRate: Int { 256_000 } // 256 kbps AAC

    public var description: String {
        switch self {
        case .high: return "1080×1920, 10 Mbps"
        case .medium: return "1080×1920, 5 Mbps"
        case .low: return "1080×1920, 2.5 Mbps"
        }
    }
}

/// Export progress info
public struct ExportProgress {
    public let fraction: Double   // 0.0 - 1.0
    public let timeElapsed: TimeInterval
    public let estimatedRemaining: TimeInterval?
}

/// Exports the edited timeline to an MP4 file using AVAssetExportSession
/// (leverages the already-built AVMutableComposition from CompositionBuilder)
public enum ExportService {

    public enum ExportError: Error, LocalizedError {
        case noClips
        case exportFailed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noClips: return "No clips to export"
            case .exportFailed(let msg): return "Export failed: \(msg)"
            case .cancelled: return "Export cancelled"
            }
        }
    }

    /// Export the timeline to a file
    /// - Parameters:
    ///   - timeline: The edited timeline
    ///   - outputURL: Destination file URL
    ///   - preset: Quality preset
    ///   - progress: Progress callback
    public static func export(
        timeline: EditTimeline,
        to outputURL: URL,
        preset: ExportPreset = .high,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        guard timeline.enabledClipCount > 0 else {
            throw ExportError.noClips
        }

        let startTime = Date()

        // Build composition from timeline
        let result = try await CompositionBuilder.build(from: timeline)

        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Use AVAssetExportSession for simplicity and HW acceleration
        guard let exportSession = AVAssetExportSession(
            asset: result.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("Cannot create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // Apply video composition (orientation fix)
        if let videoComp = result.videoComposition {
            exportSession.videoComposition = videoComp
        }

        // Apply audio mix (crossfade)
        if let audioMix = result.audioMix {
            exportSession.audioMix = audioMix
        }

        // Start export
        let exportTask = Task {
            await exportSession.export()
        }

        // Monitor progress
        let progressTask = Task {
            while !Task.isCancelled {
                let p = exportSession.progress
                let elapsed = Date().timeIntervalSince(startTime)
                let remaining: TimeInterval? = p > 0.01 ? elapsed / Double(p) * (1.0 - Double(p)) : nil

                await MainActor.run {
                    progress(ExportProgress(
                        fraction: Double(p),
                        timeElapsed: elapsed,
                        estimatedRemaining: remaining
                    ))
                }

                if p >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        // Wait for export
        await exportTask.value
        progressTask.cancel()

        // Check result
        switch exportSession.status {
        case .completed:
            let elapsed = Date().timeIntervalSince(startTime)
            print("[Export] Completed in \(String(format: "%.1f", elapsed))s → \(outputURL.lastPathComponent)")
            await MainActor.run {
                progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0))
            }
        case .failed:
            throw ExportError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.exportFailed("Unexpected status: \(exportSession.status.rawValue)")
        }
    }
}
