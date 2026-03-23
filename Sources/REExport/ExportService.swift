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

/// Exports the edited timeline to an MP4 file
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

    /// Export the timeline to a file — two paths:
    /// 1. Without subtitles: fast AVAssetExportSession
    /// 2. With subtitles: AVAssetWriter + CALayer burn-in via AVVideoCompositionCoreAnimationTool
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

        if !subtitleEntries.isEmpty, let videoComp = result.videoComposition {
            // Path 2: AVAssetWriter with subtitle burn-in
            print("[Export] Subtitle burn-in: \(subtitleEntries.count) entries")
            try await exportWithSubtitles(
                composition: result.composition,
                videoComposition: videoComp,
                audioMix: result.audioMix,
                subtitleEntries: subtitleEntries,
                subtitleStyle: subtitleStyle,
                timeline: timeline,
                outputURL: outputURL,
                preset: preset,
                startTime: startTime,
                progress: progress
            )
        } else {
            // Path 1: Fast AVAssetExportSession (no subtitles)
            print("[Export] Fast export (no subtitles)")
            try await exportFast(
                composition: result.composition,
                videoComposition: result.videoComposition,
                audioMix: result.audioMix,
                outputURL: outputURL,
                startTime: startTime,
                progress: progress
            )
        }
    }

    // MARK: - Fast Export (no subtitles)

    private static func exportFast(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        audioMix: AVMutableAudioMix?,
        outputURL: URL,
        startTime: Date,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("Cannot create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        if let vc = videoComposition { exportSession.videoComposition = vc }
        if let am = audioMix { exportSession.audioMix = am }

        let exportTask = Task { await exportSession.export() }

        let progressTask = Task {
            while !Task.isCancelled {
                let p = exportSession.progress
                let elapsed = Date().timeIntervalSince(startTime)
                let remaining: TimeInterval? = p > 0.01 ? elapsed / Double(p) * (1.0 - Double(p)) : nil
                await MainActor.run {
                    progress(ExportProgress(fraction: Double(p), timeElapsed: elapsed, estimatedRemaining: remaining))
                }
                if p >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        await exportTask.value
        progressTask.cancel()

        guard exportSession.status == .completed else {
            throw ExportError.exportFailed(exportSession.error?.localizedDescription ?? "Status: \(exportSession.status.rawValue)")
        }
        let elapsed = Date().timeIntervalSince(startTime)
        print("[Export] Fast completed in \(String(format: "%.1f", elapsed))s")
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Export with Subtitles (AVAssetWriter)

    private static func exportWithSubtitles(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix?,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        timeline: EditTimeline,
        outputURL: URL,
        preset: ExportPreset,
        startTime: Date,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        let renderSize = videoComposition.renderSize
        print("[Export] Render size: \(renderSize)")

        // Add animation tool to the videoComposition
        let animatedComp = addSubtitleLayers(
            to: videoComposition,
            subtitleEntries: subtitleEntries,
            subtitleStyle: subtitleStyle,
            timeline: timeline,
            renderSize: renderSize
        )

        // --- Reader ---
        let reader = try AVAssetReader(asset: composition)

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = animatedComp
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput? = nil
        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            if let am = audioMix { ao.audioMix = am }
            reader.add(ao)
            audioOutput = ao
        }

        // --- Writer ---
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: preset.audioBitRate
            ])
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioInput = ai
        }

        // --- Start ---
        guard reader.startReading() else {
            throw ExportError.exportFailed("Reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard writer.startWriting() else {
            throw ExportError.exportFailed("Writer failed to start: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = CMTimeGetSeconds(composition.duration)
        print("[Export] Starting frame-by-frame export, duration: \(String(format: "%.1f", totalDuration))s")

        // Write video + audio in simple loop on background thread
        try await Task.detached {
            // Video frames
            var frameCount = 0
            while reader.status == .reading {
                if videoInput.isReadyForMoreMediaData {
                    if let buffer = videoOutput.copyNextSampleBuffer() {
                        videoInput.append(buffer)
                        frameCount += 1

                        if frameCount % 30 == 0 {
                            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                            let frac = min(t / totalDuration, 0.9)
                            let elapsed = Date().timeIntervalSince(startTime)
                            Task { @MainActor in
                                progress(ExportProgress(fraction: frac, timeElapsed: elapsed, estimatedRemaining: nil))
                            }
                        }
                    } else {
                        break
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            videoInput.markAsFinished()
            print("[Export] Video done: \(frameCount) frames")

            // Audio samples
            if let audioInput = audioInput, let audioOutput = audioOutput {
                // Re-create reader for audio if needed
                while true {
                    if audioInput.isReadyForMoreMediaData {
                        if let buffer = audioOutput.copyNextSampleBuffer() {
                            audioInput.append(buffer)
                        } else {
                            break
                        }
                    } else {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                }
                audioInput.markAsFinished()
                print("[Export] Audio done")
            }
        }.value

        // Finalize
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Writer status: \(writer.status.rawValue)")
        }

        reader.cancelReading()

        let elapsed = Date().timeIntervalSince(startTime)
        print("[Export] Subtitle export completed in \(String(format: "%.1f", elapsed))s → \(outputURL.lastPathComponent)")
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Subtitle Layer Builder

    private static func addSubtitleLayers(
        to videoComposition: AVMutableVideoComposition,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        timeline: EditTimeline,
        renderSize: CGSize
    ) -> AVMutableVideoComposition {

        // Parent layer (full render size)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true  // match SwiftUI coordinate system

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
            guard let startTL = timeline.timelineTime(forSourceTime: entry.startTime),
                  let endTL = timeline.timelineTime(forSourceTime: entry.endTime) else { continue }

            let startSec = CMTimeGetSeconds(startTL)
            let endSec = CMTimeGetSeconds(endTL)
            guard endSec > startSec else { continue }

            let text = subtitleStyle.isUppercase ? entry.text.uppercased() : entry.text

            // Text layer
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
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOffset = CGSize(width: 0, height: 2)
            textLayer.shadowRadius = 3
            textLayer.shadowOpacity = 0.9

            // Position (isGeometryFlipped = true, so y goes top-down like SwiftUI)
            let yCenter = subtitleStyle.position.yCenter * scaleY
            let padding = max(SafeZone.left, SafeZone.right) * scaleX
            let width = renderSize.width - padding * 2
            let layerHeight: CGFloat = 120 * scaleY
            textLayer.frame = CGRect(x: padding, y: yCenter - layerHeight / 2, width: width, height: layerHeight)

            // Timing: hidden by default, show only during subtitle time
            textLayer.opacity = 0

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.beginTime = AVCoreAnimationBeginTimeAtZero + startSec
            fadeIn.duration = 0.05
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            textLayer.add(fadeIn, forKey: "fadeIn")

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.beginTime = AVCoreAnimationBeginTimeAtZero + endSec
            fadeOut.duration = 0.05
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            textLayer.add(fadeOut, forKey: "fadeOut")

            // Background
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
                let bgIn = fadeIn.copy() as! CABasicAnimation
                bgLayer.add(bgIn, forKey: "fadeIn")
                let bgOut = fadeOut.copy() as! CABasicAnimation
                bgLayer.add(bgOut, forKey: "fadeOut")
                overlayLayer.addSublayer(bgLayer)
            }

            overlayLayer.addSublayer(textLayer)
        }

        parentLayer.addSublayer(overlayLayer)
        print("[Export] Built \(subtitleEntries.count) subtitle layers")

        // Attach animation tool
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        return videoComposition
    }
}
