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
        struct MappedWord {
            let word: String
            let tlStart: Double
            let tlEnd: Double
        }

        // Sort enabled clips by source start for binary-search style lookup
        let enabledClips = timeline.clips.filter(\.isEnabled).sorted {
            CMTimeGetSeconds($0.sourceRange.start) < CMTimeGetSeconds($1.sourceRange.start)
        }

        // Word-level mapping: each word finds its own clip independently
        // Words in removed silence gaps are dropped; remaining words grouped into subtitle events
        let gapThreshold = 0.1 // seconds; split subtitle if timeline gap > this

        var subtitleRanges: [SubRange] = []

        for entry in subtitleEntries {
            guard !entry.words.isEmpty else {
                // Fallback: no word timings — treat whole subtitle as one "word"
                let srcMid = (CMTimeGetSeconds(entry.startTime) + CMTimeGetSeconds(entry.endTime)) / 2
                if let mapped = mapSourceTimeToTimeline(srcMid, clips: enabledClips) {
                    let s = mapped.tlOffset
                    let e = s + max(CMTimeGetSeconds(entry.endTime) - CMTimeGetSeconds(entry.startTime), 1.0)
                    let text = subtitleStyle.isUppercase ? entry.text.uppercased() : entry.text
                    subtitleRanges.append(SubRange(text: text, start: s, end: e, words: []))
                }
                continue
            }

            // Map each word to timeline time
            var mappedWords: [MappedWord] = []
            for w in entry.words {
                let wSrcStart = CMTimeGetSeconds(w.startTime)
                let wSrcEnd = CMTimeGetSeconds(w.endTime)
                let wSrcMid = (wSrcStart + wSrcEnd) / 2

                // Find clip containing this word's midpoint
                for clip in enabledClips {
                    let clipSrcStart = CMTimeGetSeconds(clip.sourceRange.start)
                    let clipSrcEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange))

                    if wSrcMid >= clipSrcStart && wSrcMid < clipSrcEnd {
                        let tlOffset = CMTimeGetSeconds(clip.timelineOffset)
                        let clampedStart = max(wSrcStart, clipSrcStart)
                        let clampedEnd = min(wSrcEnd, clipSrcEnd)
                        let tlS = tlOffset + (clampedStart - clipSrcStart) / clip.speed
                        let tlE = tlOffset + (clampedEnd - clipSrcStart) / clip.speed
                        let word = subtitleStyle.isUppercase ? w.word.uppercased() : w.word
                        mappedWords.append(MappedWord(word: word, tlStart: tlS, tlEnd: tlE))
                        break
                    }
                }
                // Word not in any clip → in removed silence gap → skip
            }

            guard !mappedWords.isEmpty else {
                print("[Export] SKIP subtitle: \(entry.text.prefix(30))... (all words in silence)")
                continue
            }

            // Group consecutive words into subtitle events (split if timeline gap > threshold)
            var groups: [[MappedWord]] = [[mappedWords[0]]]
            for i in 1..<mappedWords.count {
                let prev = mappedWords[i - 1]
                let curr = mappedWords[i]
                if curr.tlStart - prev.tlEnd > gapThreshold {
                    groups.append([curr])
                } else {
                    groups[groups.count - 1].append(curr)
                }
            }

            for group in groups {
                let text = group.map(\.word).joined(separator: " ")
                let s = group.first!.tlStart
                let e = max(group.last!.tlEnd, s + 0.3) // min 300ms display
                let words = group.map { (word: $0.word, start: $0.tlStart, end: $0.tlEnd) }
                subtitleRanges.append(SubRange(text: text, start: s, end: e, words: words))
            }
        }
        print("[Export] \(subtitleRanges.count) subtitle ranges from \(subtitleEntries.count) segments (word-level mapping)")

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

    /// Helper: find timeline time for a source time midpoint
    private static func mapSourceTimeToTimeline(_ srcTime: Double, clips: [TimelineClip]) -> (tlOffset: Double, clip: TimelineClip)? {
        for clip in clips where clip.isEnabled {
            let clipSrcStart = CMTimeGetSeconds(clip.sourceRange.start)
            let clipSrcEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange))
            if srcTime >= clipSrcStart && srcTime < clipSrcEnd {
                let tlOffset = CMTimeGetSeconds(clip.timelineOffset) + (srcTime - clipSrcStart) / clip.speed
                return (tlOffset, clip)
            }
        }
        return nil
    }

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
        let boxHeight: CGFloat = 120 * scaleY
        let fontSize = style.fontSize * min(scaleX, scaleY)

        let nsFont = NSFont(name: style.fontName, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)

        // Build attributed string with karaoke highlighting
        let normalColor = NSColor(
            red: style.textColor.red,
            green: style.textColor.green,
            blue: style.textColor.blue,
            alpha: style.textColor.alpha
        )
        let highlightColor = NSColor(
            red: style.highlightColor.red,
            green: style.highlightColor.green,
            blue: style.highlightColor.blue,
            alpha: style.highlightColor.alpha
        )

        // Find active word index
        let activeWordIdx = words.firstIndex { frameTime >= $0.start && frameTime < $0.end }

        let attrStr: NSAttributedString
        if !words.isEmpty {
            let mutable = NSMutableAttributedString()
            for (i, w) in words.enumerated() {
                let color = (i == activeWordIdx) ? highlightColor : normalColor
                let wordStr = NSAttributedString(string: (i > 0 ? " " : "") + w.word, attributes: [
                    .font: nsFont,
                    .foregroundColor: color
                ])
                mutable.append(wordStr)
            }
            attrStr = mutable
        } else {
            attrStr = NSAttributedString(string: text, attributes: [
                .font: nsFont,
                .foregroundColor: normalColor
            ])
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil, CGSize(width: textWidth, height: boxHeight), nil
        )

        let yCenter = style.position.yCenter * scaleY
        let yFromBottom = drawH - yCenter
        let textX = padding + (textWidth - textSize.width) / 2
        let textY = yFromBottom - textSize.height / 2

        // Background
        if style.backgroundOpacity > 0.01 {
            let bgRect = CGRect(
                x: textX - 16 * scaleX, y: textY - 8 * scaleY,
                width: textSize.width + 32 * scaleX, height: textSize.height + 16 * scaleY
            )
            context.setFillColor(NSColor(
                red: style.backgroundColor.red, green: style.backgroundColor.green,
                blue: style.backgroundColor.blue, alpha: style.backgroundOpacity
            ).cgColor)
            let r = 8 * min(scaleX, scaleY)
            context.addPath(CGPath(roundedRect: bgRect, cornerWidth: r, cornerHeight: r, transform: nil))
            context.fillPath()
        }

        // Shadow
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: NSColor.black.withAlphaComponent(0.9).cgColor)

        // Draw text
        let textRect = CGRect(x: textX, y: textY, width: textSize.width, height: textSize.height)
        let path = CGPath(rect: textRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(ctFrame, context)

        context.restoreGState()
    }
}
