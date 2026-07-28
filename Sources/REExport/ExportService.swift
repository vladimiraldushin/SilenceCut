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
        case .high: return "H.264, 10 Мбит/с"
        case .medium: return "H.264, 5 Мбит/с"
        case .low: return "H.264, 2,5 Мбит/с"
        }
    }
}

/// Export progress info
public struct ExportProgress {
    public let fraction: Double
    public let timeElapsed: TimeInterval
    public let estimatedRemaining: TimeInterval?
}

/// Потокобезопасный токен отмены экспорта
public final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
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

    /// Single-pass export: AVAssetReader(composition + videoComposition) → optional
    /// CG subtitle burn-in → AVAssetWriter with preset bitrate. One encode, no temp files.
    public static func export(
        timeline: EditTimeline,
        to outputURL: URL,
        preset: ExportPreset = .high,
        subtitleEntries: [SubtitleEntry] = [],
        subtitleStyle: SubtitleStyle = .classic,
        cancellation: ExportCancellationToken? = nil,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        guard timeline.enabledClipCount > 0 else { throw ExportError.noClips }

        let startTime = Date()
        let result = try await CompositionBuilder.build(from: timeline)
        try? FileManager.default.removeItem(at: outputURL)

        try await exportSinglePass(
            composition: result.composition,
            videoComposition: result.videoComposition,
            audioMix: result.audioMix,
            subtitleEntries: subtitleEntries,
            subtitleStyle: subtitleStyle,
            outputURL: outputURL,
            preset: preset,
            startTime: startTime,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// Audio-only export (M4A) — used for transcription so Whisper doesn't wait
    /// for a full video encode. Timings match the timeline exactly.
    public static func exportAudioOnly(
        timeline: EditTimeline,
        to outputURL: URL,
        cancellation: ExportCancellationToken? = nil,
        progress: @escaping (ExportProgress) -> Void = { _ in }
    ) async throws {
        guard timeline.enabledClipCount > 0 else { throw ExportError.noClips }

        let startTime = Date()
        let result = try await CompositionBuilder.build(from: timeline)
        try? FileManager.default.removeItem(at: outputURL)

        try await exportViaSession(
            asset: result.composition,
            videoComposition: nil,
            audioMix: result.audioMix,
            outputURL: outputURL,
            fileType: .m4a,
            presetName: AVAssetExportPresetAppleM4A,
            startTime: startTime,
            cancellation: cancellation,
            progress: progress
        )
        print("[Export] Audio-only export done → \(outputURL.lastPathComponent)")
    }

    // MARK: - Session-based Export (audio-only + fallback for sources without video)

    private static func exportViaSession(
        asset: AVAsset,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        outputURL: URL,
        fileType: AVFileType,
        presetName: String,
        startTime: Date,
        cancellation: ExportCancellationToken?,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ExportError.exportFailed("Cannot create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let vc = videoComposition { session.videoComposition = vc }
        if let am = audioMix { session.audioMix = am }

        let exportTask = Task { await session.export() }
        let progressTask = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    session.cancelExport()
                    break
                }
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

        if cancellation?.isCancelled == true {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        }

        guard session.status == .completed else {
            throw ExportError.exportFailed(session.error?.localizedDescription ?? "Status \(session.status.rawValue)")
        }
        let elapsed = Date().timeIntervalSince(startTime)
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Single-pass Reader → Writer Export

    private struct SubRange {
        let text: String
        let start: Double
        let end: Double
        let words: [(word: String, start: Double, end: Double)]
    }

    private static func exportSinglePass(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        audioMix: AVMutableAudioMix?,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        outputURL: URL,
        preset: ExportPreset,
        startTime: Date,
        cancellation: ExportCancellationToken?,
        progress: @escaping (ExportProgress) -> Void
    ) async throws {
        let videoTracks = try await composition.loadTracks(withMediaType: .video)

        // No video track (audio-only source) — fall back to plain session export
        guard let videoComposition, !videoTracks.isEmpty else {
            try await exportViaSession(
                asset: composition, videoComposition: nil, audioMix: audioMix,
                outputURL: outputURL, fileType: .mp4,
                presetName: AVAssetExportPresetHighestQuality,
                startTime: startTime, cancellation: cancellation, progress: progress
            )
            return
        }

        // Subtitle timings are ALREADY in timeline time (transcribed from exported timeline)
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
        let burnSubtitles = !subtitleRanges.isEmpty
        print("[Export] Single pass, \(subtitleRanges.count) subtitle ranges, preset \(preset.rawValue)")

        let renderSize = videoComposition.renderSize
        let totalDur = max(CMTimeGetSeconds(try await composition.load(.duration)), 0.001)

        // Pre-create scaled subtitle font once (constant for the whole export)
        let scaleX = renderSize.width / 1080
        let scaleY = renderSize.height / 1920
        let scaledFont = CTFontCreateWithName(
            subtitleStyle.fontName as CFString,
            subtitleStyle.fontSize * min(scaleX, scaleY),
            nil
        )

        // === Reader: composition with videoComposition (orientation baked in) ===
        let reader = try AVAssetReader(asset: composition)

        // BGRA only when we draw on frames; otherwise let the compositor pick its native format
        let videoSettings: [String: Any]? = burnSubtitles
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            : nil
        let vOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: videoSettings)
        vOutput.videoComposition = videoComposition
        reader.add(vOutput)

        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        var aOutput: AVAssetReaderAudioMixOutput? = nil
        if !audioTracks.isEmpty {
            let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            ao.audioMix = audioMix
            reader.add(ao)
            aOutput = ao
        }

        // === Writer: H.264 at preset bitrate, AAC audio ===
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30  // 1s GOP — precise passthrough splits
            ]
        ])
        vInput.expectsMediaDataInRealTime = false
        writer.add(vInput)

        var aInput: AVAssetWriterInput? = nil
        if aOutput != nil {
            // AAC settings derived from the source track format
            var sampleRate: Double = 44100
            var channels = 2
            if let fmt = try await audioTracks.first?.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                channels = max(1, min(Int(asbd.mChannelsPerFrame), 2))
            }
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: preset.audioBitRate
            ])
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            aInput = ai
        }

        guard reader.startReading() else {
            throw ExportError.exportFailed("Reader: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            throw ExportError.exportFailed("Writer: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        // === Pump both tracks via requestMediaDataWhenReady (no busy-wait) ===
        let videoQueue = DispatchQueue(label: "silencecut.export.video")
        let audioQueue = DispatchQueue(label: "silencecut.export.audio")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()

            group.enter()
            var videoDone = false
            var frameCount = 0
            vInput.requestMediaDataWhenReady(on: videoQueue) {
                guard !videoDone else { return }
                while vInput.isReadyForMoreMediaData {
                    if cancellation?.isCancelled == true {
                        videoDone = true
                        vInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let buf = vOutput.copyNextSampleBuffer() else {
                        videoDone = true
                        vInput.markAsFinished()
                        print("[Export] Video done: \(frameCount) frames")
                        group.leave()
                        return
                    }
                    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buf))
                    if burnSubtitles,
                       let sub = subtitleRanges.first(where: { t >= $0.start && t < $0.end }),
                       let pb = CMSampleBufferGetImageBuffer(buf) {
                        drawSubtitle(text: sub.text, words: sub.words, frameTime: t,
                                     on: pb, renderSize: renderSize,
                                     style: subtitleStyle, font: scaledFont)
                    }
                    if !vInput.append(buf) {
                        videoDone = true
                        vInput.markAsFinished()
                        group.leave()
                        return
                    }
                    frameCount += 1
                    if frameCount % 30 == 0 {
                        let frac = min(t / totalDur, 1.0)
                        let elapsed = Date().timeIntervalSince(startTime)
                        let remaining: TimeInterval? = frac > 0.01 ? elapsed / frac * (1.0 - frac) : nil
                        Task { @MainActor in
                            progress(ExportProgress(fraction: frac, timeElapsed: elapsed, estimatedRemaining: remaining))
                        }
                    }
                }
            }

            if let aInput, let aOutput {
                group.enter()
                var audioDone = false
                aInput.requestMediaDataWhenReady(on: audioQueue) {
                    guard !audioDone else { return }
                    while aInput.isReadyForMoreMediaData {
                        if cancellation?.isCancelled == true {
                            audioDone = true
                            aInput.markAsFinished()
                            group.leave()
                            return
                        }
                        guard let buf = aOutput.copyNextSampleBuffer() else {
                            audioDone = true
                            aInput.markAsFinished()
                            group.leave()
                            return
                        }
                        if !aInput.append(buf) {
                            audioDone = true
                            aInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) { cont.resume() }
        }

        // === Finalize ===
        if cancellation?.isCancelled == true {
            if reader.status == .reading { reader.cancelReading() }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        }
        if reader.status == .failed || writer.status == .failed || writer.error != nil {
            if reader.status == .reading { reader.cancelReading() }
            writer.cancelWriting()
            throw ExportError.exportFailed(
                writer.error?.localizedDescription
                ?? reader.error?.localizedDescription
                ?? "неизвестная ошибка"
            )
        }
        if reader.status == .reading { reader.cancelReading() }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "Writer status \(writer.status.rawValue)")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("[Export] Done in \(String(format: "%.1f", elapsed))s → \(outputURL.lastPathComponent)")
        await MainActor.run { progress(ExportProgress(fraction: 1.0, timeElapsed: elapsed, estimatedRemaining: 0)) }
    }

    // MARK: - Core Graphics Subtitle Rendering

    /// Draw subtitle with karaoke word highlighting via Core Graphics.
    /// Frames come from the video composition, so orientation is already baked in.
    private static func drawSubtitle(
        text: String,
        words: [(word: String, start: Double, end: Double)],
        frameTime: Double,
        on pixelBuffer: CVPixelBuffer,
        renderSize: CGSize,
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

        let drawW = renderSize.width
        let drawH = renderSize.height
        let scaleX = drawW / 1080
        let scaleY = drawH / 1920

        let padding = max(SafeZone.left, SafeZone.right) * scaleX
        let textWidth = drawW - padding * 2
        let maxBoxHeight: CGFloat = 400 * scaleY // enough for 6+ lines

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
                    .font: font,
                    .foregroundColor: color
                ] as [NSAttributedString.Key: Any])
                mutable.append(wordStr)
            }
            attrStr = mutable
        } else {
            attrStr = NSAttributedString(string: text, attributes: [
                .font: font,
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
                        .font: font,
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
