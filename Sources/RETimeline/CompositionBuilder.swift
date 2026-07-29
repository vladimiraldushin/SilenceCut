import Foundation
import AVFoundation
import RECore

/// Builds a disposable AVMutableComposition from the EDL model.
/// Called on every timeline change. Cost: <1ms for dozens of clips.
public enum CompositionBuilder {

    public struct Result {
        public let composition: AVMutableComposition
        public let videoComposition: AVMutableVideoComposition?
        public let audioMix: AVMutableAudioMix?
    }

    /// Build composition from timeline — the core function.
    /// `options` drive framing (aspect crop), jump-cut zoom and audio gain;
    /// preview and export both go through here, so what you see is what you get.
    public static func build(
        from timeline: EditTimeline,
        options: RenderOptions = .default
    ) async throws -> Result {
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BuildError.cannotCreateTrack }

        var audioTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertionTime = CMTime.zero
        var sourceTransform: CGAffineTransform = .identity
        var sourceNaturalSize: CGSize = .zero
        var nominalFrameRate: Float = 30

        // Timeline offsets and lengths of every enabled clip — jump-cut zoom needs both:
        // where the cuts are and how long each piece stays on screen
        var clipStarts: [CMTime] = []
        var clipDurations: [Double] = []

        for clip in timeline.clips where clip.isEnabled {
            let asset = AVURLAsset(url: clip.sourceURL)

            // Insert video
            let videoTracks = try await asset.loadTracks(withMediaType: AVMediaType.video)
            if let srcVideo = videoTracks.first {
                try videoTrack.insertTimeRange(clip.sourceRange, of: srcVideo, at: insertionTime)

                // Capture transform + size from first clip (all clips share same source)
                if sourceNaturalSize == .zero {
                    sourceNaturalSize = try await srcVideo.load(.naturalSize)
                    sourceTransform = try await srcVideo.load(.preferredTransform)
                    let fps = try await srcVideo.load(.nominalFrameRate)
                    if fps > 1 { nominalFrameRate = fps }
                }
            }

            // Insert audio
            let audioTracks = try await asset.loadTracks(withMediaType: AVMediaType.audio)
            if let srcAudio = audioTracks.first,
               let dstAudio = audioTrack {
                try dstAudio.insertTimeRange(clip.sourceRange, of: srcAudio, at: insertionTime)
            }

            clipStarts.append(insertionTime)
            clipDurations.append(CMTimeGetSeconds(clip.effectiveDuration))
            insertionTime = CMTimeAdd(insertionTime, clip.effectiveDuration)
        }

        // Источник без звука — пустая аудиодорожка ломает AVAssetReader при экспорте, убираем её.
        // У незаполненной дорожки timeRange невалиден, поэтому сравнение с .zero тут не годится.
        if let track = audioTrack {
            let seconds = CMTimeGetSeconds(track.timeRange.duration)
            if !seconds.isFinite || seconds <= 0 {
                composition.removeTrack(track)
                audioTrack = nil
            }
        }

        // Build video composition: orientation + aspect crop + jump-cut zoom
        var videoComp: AVMutableVideoComposition? = nil

        if sourceNaturalSize != .zero {
            let orientedSize = transformedSize(sourceNaturalSize, transform: sourceTransform)
            let renderSize = options.outputAspect.renderSize ?? orientedSize

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: insertionTime)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            // Step change at cuts where the zoom actually differs — no interpolation,
            // and no redundant transforms while the scale is being held
            let scales = options.zoomScales(forClipDurations: clipDurations)
            var appliedZoom: Double? = nil
            for (index, start) in clipStarts.enumerated() {
                let zoom = scales[index]
                guard appliedZoom != zoom else { continue }
                let transform = renderTransform(
                    sourceTransform: sourceTransform,
                    orientedSize: orientedSize,
                    targetSize: renderSize,
                    zoom: zoom
                )
                layerInstruction.setTransform(transform, at: start)
                appliedZoom = zoom
            }
            instruction.layerInstructions = [layerInstruction]

            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, Int(nominalFrameRate.rounded())))))
            vc.instructions = [instruction]
            videoComp = vc
        }

        // Audio: 30ms ramps at cuts (kills clicks) + loudness normalization gain
        var audioMix: AVMutableAudioMix? = nil
        let gain = Float(max(0, options.audioGain))
        let needsGain = abs(options.audioGain - 1.0) > 0.001

        if let dstAudio = audioTrack, timeline.enabledClipCount > 1 || needsGain {
            let params = AVMutableAudioMixInputParameters(track: dstAudio)
            let fadeDuration = CMTime(seconds: 0.03, preferredTimescale: 600)

            if timeline.enabledClipCount > 1 {
                var segmentStart = CMTime.zero
                for clip in timeline.clips where clip.isEnabled {
                    let segEnd = CMTimeAdd(segmentStart, clip.effectiveDuration)

                    // Fade in at start of each segment
                    params.setVolumeRamp(
                        fromStartVolume: 0.0, toEndVolume: gain,
                        timeRange: CMTimeRange(start: segmentStart, duration: fadeDuration)
                    )

                    // Fade out at end of each segment
                    let fadeOutStart = CMTimeSubtract(segEnd, fadeDuration)
                    if CMTimeCompare(fadeOutStart, segmentStart) > 0 {
                        params.setVolumeRamp(
                            fromStartVolume: gain, toEndVolume: 0.0,
                            timeRange: CMTimeRange(start: fadeOutStart, duration: fadeDuration)
                        )
                    }

                    segmentStart = segEnd
                }
            } else {
                // Single clip — gain only
                params.setVolume(gain, at: .zero)
            }

            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        return Result(composition: composition, videoComposition: videoComp, audioMix: audioMix)
    }

    // MARK: - Transform Math (pure, testable)

    /// Transform placing an oriented source frame into the target frame:
    /// source orientation → aspect-fill scale (center crop) → zoom about the center.
    public static func renderTransform(
        sourceTransform: CGAffineTransform,
        orientedSize: CGSize,
        targetSize: CGSize,
        zoom: Double
    ) -> CGAffineTransform {
        guard orientedSize.width > 0, orientedSize.height > 0 else { return sourceTransform }

        let fillScale = max(targetSize.width / orientedSize.width,
                            targetSize.height / orientedSize.height)
        let scale = fillScale * CGFloat(max(0.01, zoom))

        // Center the scaled frame in the target — crops the overflow symmetrically
        let tx = (targetSize.width - orientedSize.width * scale) / 2
        let ty = (targetSize.height - orientedSize.height * scale) / 2

        return sourceTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Calculate the output size after applying the transform
    public static func transformedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    public enum BuildError: Error, LocalizedError {
        case cannotCreateTrack
        case noVideoTrack
        case insertFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateTrack: return "Cannot create composition track"
            case .noVideoTrack: return "No video track in source"
            case .insertFailed(let msg): return "Insert failed: \(msg)"
            }
        }
    }
}
