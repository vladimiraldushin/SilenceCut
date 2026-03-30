import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
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

    // MARK: - Two-pass Export with CG Subtitle Burn-in
    // Pass 1: AVAssetExportSession → temp.mp4 (reliable, no auth issues)
    // Pass 2: AVAssetReader(temp.mp4) → draw subtitles → AVAssetWriter → final.mp4

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
        struct SubRange {
            let text: String
            let start: Double
            let end: Double
            let words: [(word: String, start: Double, end: Double)]
        }

        // Subtitle timings are ALREADY in timeline time (transcribed from exported temp video)
        // No source→timeline mapping needed!
        let subtitleRanges: [SubRange] = subtitleEntries.compactMap { entry in
            let s = CMTimeGetSeconds(entry.startTime)
            let e = CMTimeGetSeconds(entry.endTime)
            guard e > s else { return nil }

            let text = subtitleStyle.isUppercase ? entry.text.uppercased() : entry.text
            let words: [(word: String, start: Double, end: Double)] = entry.words.map { w in
                let word = subtitleStyle.isUppercase ? w.word.uppercased() : w.word
                return (word: word, start: CMTimeGetSeconds(w.startTime), end: CMTimeGetSeconds(w.endTime))
            }
            return SubRange(text: text, start: s, end: e, words: words)
        }
        print("[Export] \(subtitleRanges.count)/\(subtitleEntries.count) subtitle ranges (direct timeline time, no mapping)")

        // === PASS 1: Export composition to temp file ===
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("silencecut_\(UUID().uuidString).mp4")
        print("[Export] Pass 1: composition → \(tempURL.lastPathComponent)")

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportFailed("Cannot create export session")
        }
        session.outputURL = tempURL
        session.outputFileType = .mp4
        if let vc = videoComposition { session.videoComposition = vc }
        if let am = audioMix { session.audioMix = am }

        let pass1Task = Task { await session.export() }
        let pass1Progress = Task {
            while !Task.isCancelled {
                let p = session.progress
                await MainActor.run { progress(ExportProgress(fraction: Double(p) * 0.4, timeElapsed: Date().timeIntervalSince(startTime), estimatedRemaining: nil)) }
                if p >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await pass1Task.value
        pass1Progress.cancel()

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExportError.exportFailed("Pass 1: \(session.error?.localizedDescription ?? "failed")")
        }
        print("[Export] Pass 1 done ✓")

        // === PASS 2: Read temp → burn subtitles → write final ===
        defer { try? FileManager.default.removeItem(at: tempURL) }
        print("[Export] Pass 2: burn-in subtitles")

        let tempAsset = AVURLAsset(url: tempURL)
        let reader = try AVAssetReader(asset: tempAsset)

        guard let vTrack = try await tempAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.exportFailed("No video in temp")
        }
        let natSize = try await vTrack.load(.naturalSize)
        let xform = try await vTrack.load(.preferredTransform)
        let renderSize = videoComposition?.renderSize ?? CGSize(width: 1080, height: 1920)
        print("[Export] Pass 2: natural=\(natSize), transform=\(xform), render=\(renderSize)")

        let vOutput = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(vOutput)

        var aOutput: AVAssetReaderTrackOutput? = nil
        if let aTrack = try await tempAsset.loadTracks(withMediaType: .audio).first {
            let ao = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            reader.add(ao)
            aOutput = ao
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(natSize.width),
            AVVideoHeightKey: Int(natSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        vInput.transform = xform
        vInput.expectsMediaDataInRealTime = false
        writer.add(vInput)

        var aInput: AVAssetWriterInput? = nil
        if let aTrack2 = try await tempAsset.loadTracks(withMediaType: .audio).first {
            let fmtDescs = try await aTrack2.load(.formatDescriptions)
            let hint = fmtDescs.first
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            aInput = ai
        }

        guard reader.startReading() else {
            throw ExportError.exportFailed("Pass 2 reader: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            throw ExportError.exportFailed("Pass 2 writer: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let totalDur = CMTimeGetSeconds(try await tempAsset.load(.duration))
        let ctFont = CTFontCreateWithName((subtitleStyle.fontName as CFString), subtitleStyle.fontSize, nil)

        print("[Export] Pass 2: processing \(String(format: "%.1f", totalDur))s")

        try await Task.detached {
            var fc = 0
            var videoDone = false
            var audioDone = (aInput == nil)

            while reader.status == .reading && !(videoDone && audioDone) {
                var didWork = false

                // Video
                if !videoDone && vInput.isReadyForMoreMediaData {
                    if let buf = vOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(buf)
                        let t = CMTimeGetSeconds(pts)

                        if let sub = subtitleRanges.first(where: { t >= $0.start && t < $0.end }),
                           let pb = CMSampleBufferGetImageBuffer(buf) {
                            drawSubtitle(text: sub.text, words: sub.words, frameTime: t,
                                         on: pb, renderSize: renderSize,
                                         sourceTransform: xform, style: subtitleStyle, font: ctFont)
                        }
                        vInput.append(buf)
                        fc += 1
                        didWork = true

                        if fc % 60 == 0 {
                            let frac = 0.4 + min(t / totalDur, 1.0) * 0.6
                            Task { @MainActor in
                                progress(ExportProgress(fraction: frac, timeElapsed: Date().timeIntervalSince(startTime), estimatedRemaining: nil))
                            }
                        }
                    } else {
                        vInput.markAsFinished()
                        videoDone = true
                        print("[Export] Pass 2 video: \(fc) frames")
                    }
                }

                // Audio (interleaved)
                if !audioDone, let aIn = aInput, let aOut = aOutput, aIn.isReadyForMoreMediaData {
                    if let b = aOut.copyNextSampleBuffer() {
                        aIn.append(b)
                        didWork = true
                    } else {
                        aIn.markAsFinished()
                        audioDone = true
                        print("[Export] Pass 2 audio done")
                    }
                }

                if !didWork {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }

            // Finish any remaining
            if !videoDone { vInput.markAsFinished() }
            if !audioDone, let aIn = aInput { aIn.markAsFinished() }
        }.value

        await writer.finishWriting()
        reader.cancelReading()

        guard writer.status == .completed else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Writer: \(writer.status.rawValue)")
        }
        let elapsed = Date().timeIntervalSince(startTime)
        print("[Export] Done in \(String(format: "%.1f", elapsed))s → \(outputURL.lastPathComponent)")
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Core Graphics Subtitle Rendering

    /// Draw subtitle with karaoke word highlighting via Core Graphics
    private static func drawSubtitle(
        text: String,
        words: [(word: String, start: Double, end: Double)],
        frameTime: Double,
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

        context.saveGState()
        context.concatenate(sourceTransform)

        let drawW = renderSize.width
        let drawH = renderSize.height
        let scaleX = drawW / 1080
        let scaleY = drawH / 1920

        let padding = max(SafeZone.left, SafeZone.right) * scaleX
        let textWidth = drawW - padding * 2
        let maxBoxHeight: CGFloat = 400 * scaleY // enough for 6+ lines
        let fontSize = style.fontSize * min(scaleX, scaleY)

        let ctFont = CTFontCreateWithName(style.fontName as CFString, fontSize, nil)

        // Build attributed string with karaoke highlighting
        let normalColor = CGColor(
            red: style.textColor.red,
            green: style.textColor.green,
            blue: style.textColor.blue,
            alpha: style.textColor.alpha
        )
        let highlightColor = CGColor(
            red: style.highlightColor.red,
            green: style.highlightColor.green,
            blue: style.highlightColor.blue,
            alpha: style.highlightColor.alpha
        )

        // Find active word index
        let activeWordIdx = words.firstIndex { frameTime >= $0.start && frameTime < $0.end }
        let useGlow = style.highlightMode == .glow

        // For glow mode: inactive words are dimmed
        let dimColor = CGColor(
            red: style.textColor.red,
            green: style.textColor.green,
            blue: style.textColor.blue,
            alpha: useGlow ? style.textColor.alpha * 0.5 : style.textColor.alpha
        )

        let attrStr: NSAttributedString
        if !words.isEmpty {
            let mutable = NSMutableAttributedString()
            for (i, w) in words.enumerated() {
                let isActive = i == activeWordIdx
                let color: CGColor
                if useGlow {
                    color = isActive ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : dimColor
                } else {
                    color = isActive ? highlightColor : normalColor
                }
                let wordStr = NSAttributedString(string: (i > 0 ? " " : "") + w.word, attributes: [
                    .font: ctFont,
                    .foregroundColor: color
                ] as [NSAttributedString.Key: Any])
                mutable.append(wordStr)
            }
            attrStr = mutable
        } else {
            attrStr = NSAttributedString(string: text, attributes: [
                .font: ctFont,
                .foregroundColor: normalColor
            ] as [NSAttributedString.Key: Any])
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        // Calculate actual text size (unconstrained height to avoid truncation)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil, CGSize(width: textWidth, height: maxBoxHeight), nil
        )

        let yCenter = style.effectiveYCenter * scaleY
        let yFromBottom = drawH - yCenter
        let textX = padding + (textWidth - textSize.width) / 2
        // Position so text is centered vertically at yCenter
        let textY = yFromBottom - textSize.height / 2

        // Background
        if style.backgroundOpacity > 0.01 {
            let basePadX: CGFloat = style.backgroundPaddingH * scaleX
            let basePadY: CGFloat = style.backgroundPaddingV * scaleY
            let blurRadius = style.backgroundBlurRadius * min(scaleX, scaleY)
            let isOval = style.backgroundShape == .oval

            func bgPath(rect: CGRect) -> CGPath {
                if isOval {
                    return CGPath(ellipseIn: rect, transform: nil)
                } else {
                    let r = 8 * min(scaleX, scaleY)
                    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                }
            }

            if blurRadius > 1 {
                let steps = 8
                for i in 0..<steps {
                    let frac = CGFloat(i) / CGFloat(steps - 1)
                    let expand = frac * blurRadius
                    let alpha = style.backgroundOpacity * (1.0 - frac * 0.85)

                    let bgRect = CGRect(
                        x: textX - basePadX - expand,
                        y: textY - basePadY - expand,
                        width: textSize.width + basePadX * 2 + expand * 2,
                        height: textSize.height + basePadY * 2 + expand * 2
                    )
                    context.setFillColor(CGColor(
                        red: style.backgroundColor.red, green: style.backgroundColor.green,
                        blue: style.backgroundColor.blue, alpha: alpha
                    ))
                    context.addPath(bgPath(rect: bgRect))
                    context.fillPath()
                }
            } else {
                let bgRect = CGRect(
                    x: textX - basePadX, y: textY - basePadY,
                    width: textSize.width + basePadX * 2, height: textSize.height + basePadY * 2
                )
                context.setFillColor(CGColor(
                    red: style.backgroundColor.red, green: style.backgroundColor.green,
                    blue: style.backgroundColor.blue, alpha: style.backgroundOpacity
                ))
                context.addPath(bgPath(rect: bgRect))
                context.fillPath()
            }
        }

        let textRect = CGRect(x: textX, y: textY, width: textSize.width, height: textSize.height)
        let path = CGPath(rect: textRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        // Glow passes BEFORE main text (rendered underneath)
        if useGlow && activeWordIdx != nil {
            // Build glow-only attributed string (only active word visible)
            let glowStr: NSAttributedString = {
                let mutable = NSMutableAttributedString()
                for (i, w) in words.enumerated() {
                    let isActive = i == activeWordIdx
                    let color = isActive ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                    let wordStr = NSAttributedString(string: (i > 0 ? " " : "") + w.word, attributes: [
                        .font: ctFont,
                        .foregroundColor: color
                    ] as [NSAttributedString.Key: Any])
                    mutable.append(wordStr)
                }
                return mutable
            }()
            let glowFramesetter = CTFramesetterCreateWithAttributedString(glowStr)
            let glowFrame = CTFramesetterCreateFrame(glowFramesetter, CFRange(location: 0, length: 0), path, nil)

            // Multiple glow passes for intensity
            for blur in [12.0, 6.0, 3.0] {
                context.saveGState()
                context.setShadow(offset: .zero, blur: blur * min(scaleX, scaleY), color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
                CTFrameDraw(glowFrame, context)
                context.restoreGState()
            }
        }

        // Main text with drop shadow
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        CTFrameDraw(ctFrame, context)

        context.restoreGState()
    }
}
