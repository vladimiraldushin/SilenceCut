import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import AppKit
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
        subtitleEntries: [SubtitleEntry] = [],
        subtitleStyle: SubtitleStyle = .classic,
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

        // Build subtitle overlay using Core Animation if subtitles exist
        if !subtitleEntries.isEmpty, let videoComp = result.videoComposition {
            let renderSize = videoComp.renderSize
            let subtitleVideoComp = buildSubtitleComposition(
                baseComposition: result.composition,
                videoComposition: videoComp,
                subtitleEntries: subtitleEntries,
                subtitleStyle: subtitleStyle,
                timeline: timeline,
                renderSize: renderSize
            )
            exportSession.videoComposition = subtitleVideoComp
        } else if let videoComp = result.videoComposition {
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

    // MARK: - Subtitle Burn-in via Core Animation

    /// Creates AVVideoComposition with subtitle CATextLayers using AVVideoCompositionCoreAnimationTool
    private static func buildSubtitleComposition(
        baseComposition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        timeline: EditTimeline,
        renderSize: CGSize
    ) -> AVMutableVideoComposition {

        // Parent layer (full render size)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        // Video layer
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)

        // Subtitle overlay layer
        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: renderSize)

        // Scale: subtitle positions are in 1080×1920 canvas
        let scaleX = renderSize.width / 1080
        let scaleY = renderSize.height / 1920

        for entry in subtitleEntries {
            // Map source time → timeline time for this entry
            guard let startTL = timeline.timelineTime(forSourceTime: entry.startTime),
                  let endTL = timeline.timelineTime(forSourceTime: entry.endTime) else { continue }

            let startSec = CMTimeGetSeconds(startTL)
            let endSec = CMTimeGetSeconds(endTL)
            guard endSec > startSec else { continue }

            // Build subtitle text
            let text = subtitleStyle.isUppercase ? entry.text.uppercased() : entry.text

            // Create text layer
            let textLayer = CATextLayer()
            let fontSize = subtitleStyle.fontSize * min(scaleX, scaleY)
            let font = NSFont(name: subtitleStyle.fontName, size: fontSize)
                ?? NSFont.boldSystemFont(ofSize: fontSize)

            let attrString = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor(
                    red: subtitleStyle.textColor.red,
                    green: subtitleStyle.textColor.green,
                    blue: subtitleStyle.textColor.blue,
                    alpha: subtitleStyle.textColor.alpha
                )
            ])
            textLayer.string = attrString
            textLayer.isWrapped = true
            textLayer.alignmentMode = .center
            textLayer.contentsScale = 2

            // Shadow for readability
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOffset = CGSize(width: 0, height: -1)
            textLayer.shadowRadius = 2
            textLayer.shadowOpacity = 0.8

            // Position (Core Animation: y=0 is BOTTOM, opposite of SwiftUI)
            let yCenter = subtitleStyle.position.yCenter * scaleY
            let yFromBottom = renderSize.height - yCenter
            let padding = SafeZone.left * scaleX
            let width = renderSize.width - padding * 2
            textLayer.frame = CGRect(x: padding, y: yFromBottom - 40, width: width, height: 80)

            // Animated: show only during subtitle's time range
            // Using AVCoreAnimationBeginTimeAtZero convention
            textLayer.opacity = 0

            // Fade in
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.beginTime = AVCoreAnimationBeginTimeAtZero + startSec
            fadeIn.duration = 0.05
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            textLayer.add(fadeIn, forKey: "fadeIn")

            // Fade out
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.beginTime = AVCoreAnimationBeginTimeAtZero + endSec
            fadeOut.duration = 0.05
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            textLayer.add(fadeOut, forKey: "fadeOut")

            // Background pill for classic style
            if subtitleStyle.backgroundOpacity > 0.01 {
                let bgLayer = CALayer()
                bgLayer.frame = textLayer.frame.insetBy(dx: -12 * scaleX, dy: -6 * scaleY)
                bgLayer.backgroundColor = NSColor(
                    red: subtitleStyle.backgroundColor.red,
                    green: subtitleStyle.backgroundColor.green,
                    blue: subtitleStyle.backgroundColor.blue,
                    alpha: subtitleStyle.backgroundOpacity
                ).cgColor
                bgLayer.cornerRadius = 8 * min(scaleX, scaleY)
                bgLayer.opacity = 0

                // Same timing animations
                let bgFadeIn = fadeIn.copy() as! CABasicAnimation
                bgLayer.add(bgFadeIn, forKey: "fadeIn")
                let bgFadeOut = fadeOut.copy() as! CABasicAnimation
                bgLayer.add(bgFadeOut, forKey: "fadeOut")

                overlayLayer.addSublayer(bgLayer)
            }

            overlayLayer.addSublayer(textLayer)
        }

        parentLayer.addSublayer(overlayLayer)

        // Create new video composition with animation tool
        let animTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        videoComposition.animationTool = animTool

        return videoComposition
    }
}
