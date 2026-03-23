import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreText
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
        case .high: return 10_000_000
        case .medium: return 5_000_000
        case .low: return 2_500_000
        }
    }

    public var audioBitRate: Int { 256_000 }

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
    public let fraction: Double
    public let timeElapsed: TimeInterval
    public let estimatedRemaining: TimeInterval?
}

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

    public static func export(
        timeline: EditTimeline,
        to outputURL: URL,
        preset: ExportPreset = .high,
        subtitleEntries: [SubtitleEntry] = [],
        subtitleStyle: SubtitleStyle = .classic,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        guard timeline.enabledClipCount > 0 else { throw ExportError.noClips }

        let startTime = Date()
        let result = try await CompositionBuilder.build(from: timeline)
        try? FileManager.default.removeItem(at: outputURL)

        if !subtitleEntries.isEmpty {
            print("[Export] Subtitle burn-in: \(subtitleEntries.count) entries via Core Graphics")
            try await exportWithCGSubtitles(
                composition: result.composition,
                videoComposition: result.videoComposition,
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

    // MARK: - Fast Export

    private static func exportFast(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        audioMix: AVMutableAudioMix?,
        outputURL: URL,
        startTime: Date,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportFailed("Cannot create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let vc = videoComposition { session.videoComposition = vc }
        if let am = audioMix { session.audioMix = am }

        let exportTask = Task { await session.export() }
        let progressTask = Task {
            while !Task.isCancelled {
                let p = session.progress
                let elapsed = Date().timeIntervalSince(startTime)
                let remaining: TimeInterval? = p > 0.01 ? elapsed / Double(p) * (1.0 - Double(p)) : nil
                await MainActor.run { progress(ExportProgress(fraction: Double(p), timeElapsed: elapsed, estimatedRemaining: remaining)) }
                if p >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await exportTask.value
        progressTask.cancel()

        guard session.status == .completed else {
            throw ExportError.exportFailed(session.error?.localizedDescription ?? "Status \(session.status.rawValue)")
        }
        let elapsed = Date().timeIntervalSince(startTime)
        print("[Export] Fast completed in \(String(format: "%.1f", elapsed))s")
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Export with Core Graphics Subtitle Burn-in

    private static func exportWithCGSubtitles(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        audioMix: AVMutableAudioMix?,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        timeline: EditTimeline,
        outputURL: URL,
        preset: ExportPreset,
        startTime: Date,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        let renderSize = videoComposition?.renderSize ?? CGSize(width: 1080, height: 1920)
        print("[Export] Render size: \(renderSize)")

        // Pre-compute subtitle timeline ranges
        let subtitleRanges = subtitleEntries.compactMap { entry -> (text: String, start: Double, end: Double)? in
            guard let startTL = timeline.timelineTime(forSourceTime: entry.startTime),
                  let endTL = timeline.timelineTime(forSourceTime: entry.endTime) else { return nil }
            let s = CMTimeGetSeconds(startTL), e = CMTimeGetSeconds(endTL)
            guard e > s else { return nil }
            let text = subtitleStyle.isUppercase ? entry.text.uppercased() : entry.text
            return (text: text, start: s, end: e)
        }
        print("[Export] \(subtitleRanges.count) subtitle ranges prepared")

        // --- Reader ---
        let reader = try AVAssetReader(asset: composition)

        // Use simple track output (not VideoCompositionOutput which blocks)
        guard let videoTrack = composition.tracks(withMediaType: .video).first else {
            throw ExportError.exportFailed("No video track")
        }
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(videoOutput)

        // Get source transform for manual rotation
        let sourceTransform = videoTrack.preferredTransform

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

        // Writer input with correct orientation
        // For portrait iPhone video: source is 1920x1080 rotated 90°
        // AVAssetWriterInput.transform handles the rotation metadata
        let sourceSize = videoTrack.naturalSize
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(sourceSize.width),
            AVVideoHeightKey: Int(sourceSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.transform = sourceTransform
        videoInput.expectsMediaDataInRealTime = false
        print("[Export] Source: \(sourceSize), transform: \(sourceTransform), render: \(renderSize)")

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
            throw ExportError.exportFailed("Reader: \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard writer.startWriting() else {
            throw ExportError.exportFailed("Writer: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = CMTimeGetSeconds(composition.duration)
        print("[Export] Starting CG burn-in, duration: \(String(format: "%.1f", totalDuration))s")

        // Pre-build font and attributes for subtitle rendering
        let fontSize = subtitleStyle.fontSize
        let ctFont = CTFontCreateWithName((subtitleStyle.fontName as CFString), fontSize, nil)

        // --- Process frames ---
        try await Task.detached {
            var frameCount = 0

            while reader.status == .reading {
                if videoInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else { break }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let timeSec = CMTimeGetSeconds(pts)

                    // Find active subtitle at this frame time
                    let activeSubtitle = subtitleRanges.first { timeSec >= $0.start && timeSec < $0.end }

                    if let sub = activeSubtitle, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        // Draw subtitle onto pixel buffer (in source orientation)
                        drawSubtitle(
                            text: sub.text,
                            on: pixelBuffer,
                            renderSize: renderSize,
                            sourceTransform: sourceTransform,
                            style: subtitleStyle,
                            font: ctFont
                        )
                    }

                    // Write frame
                    videoInput.append(sampleBuffer)

                    frameCount += 1
                    if frameCount % 30 == 0 {
                        let frac = min(timeSec / totalDuration, 0.9)
                        let elapsed = Date().timeIntervalSince(startTime)
                        Task { @MainActor in
                            progress(ExportProgress(fraction: frac, timeElapsed: elapsed, estimatedRemaining: nil))
                        }
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            videoInput.markAsFinished()
            print("[Export] Video done: \(frameCount) frames")

            // Audio
            if let audioInput = audioInput, let audioOutput = audioOutput {
                while true {
                    if audioInput.isReadyForMoreMediaData {
                        guard let buffer = audioOutput.copyNextSampleBuffer() else { break }
                        audioInput.append(buffer)
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
        reader.cancelReading()

        guard writer.status == .completed else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Writer status: \(writer.status.rawValue)")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("[Export] Subtitle export completed in \(String(format: "%.1f", elapsed))s → \(outputURL.lastPathComponent)")
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Core Graphics Subtitle Rendering

    /// Draw subtitle text directly onto a CVPixelBuffer using Core Graphics + Core Text
    /// sourceTransform: the video track's preferredTransform (e.g. 90° for portrait iPhone)
    private static func drawSubtitle(
        text: String,
        on pixelBuffer: CVPixelBuffer,
        renderSize: CGSize,
        sourceTransform: CGAffineTransform,
        style: SubtitleStyle,
        font: CTFont
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let bufW = CVPixelBufferGetWidth(pixelBuffer)
        let bufH = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: bufW,
            height: bufH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Apply the source transform so subtitles appear correctly oriented
        // For portrait iPhone: buffer is 1920×1080 (landscape), transform rotates to 1080×1920
        context.saveGState()
        context.concatenate(sourceTransform)

        // Now we draw in renderSize coordinates (e.g. 1080×1920 for portrait)
        let drawW = renderSize.width
        let drawH = renderSize.height

        // Scale from 1080×1920 design coordinates
        let scaleX = drawW / 1080
        let scaleY = drawH / 1920

        // Text area
        let padding = max(SafeZone.left, SafeZone.right) * scaleX
        let textWidth = drawW - padding * 2
        let boxHeight: CGFloat = 120 * scaleY

        // Build attributed string
        let fontSize = style.fontSize * min(scaleX, scaleY)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: style.fontName, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor(
                red: style.textColor.red,
                green: style.textColor.green,
                blue: style.textColor.blue,
                alpha: style.textColor.alpha
            )
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil, CGSize(width: textWidth, height: boxHeight), nil
        )

        // Position: yCenter in top-down coordinates → convert to CG bottom-up
        let yCenter = style.position.yCenter * scaleY
        let yFromBottom = drawH - yCenter

        let textX = padding + (textWidth - textSize.width) / 2
        let textY = yFromBottom - textSize.height / 2

        // Background
        if style.backgroundOpacity > 0.01 {
            let bgRect = CGRect(
                x: textX - 16 * scaleX,
                y: textY - 8 * scaleY,
                width: textSize.width + 32 * scaleX,
                height: textSize.height + 16 * scaleY
            )
            context.setFillColor(NSColor(
                red: style.backgroundColor.red,
                green: style.backgroundColor.green,
                blue: style.backgroundColor.blue,
                alpha: style.backgroundOpacity
            ).cgColor)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 8 * min(scaleX, scaleY), cornerHeight: 8 * min(scaleX, scaleY), transform: nil)
            context.addPath(bgPath)
            context.fillPath()
        }

        // Text shadow
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: NSColor.black.withAlphaComponent(0.9).cgColor)

        // Draw text via CTFrame (CG native coordinates, y=0 bottom)
        let textRect = CGRect(x: textX, y: textY, width: textSize.width, height: textSize.height)
        let path = CGPath(rect: textRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(ctFrame, context)

        context.restoreGState()
    }
}
