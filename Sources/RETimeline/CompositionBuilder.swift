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

    /// Build composition from timeline — the core function
    public static func build(from timeline: EditTimeline) async throws -> Result {
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BuildError.cannotCreateTrack }

        let audioTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertionTime = CMTime.zero
        var sourceTransform: CGAffineTransform = .identity
        var sourceNaturalSize: CGSize = .zero

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
                }
            }

            // Insert audio
            let audioTracks = try await asset.loadTracks(withMediaType: AVMediaType.audio)
            if let srcAudio = audioTracks.first,
               let dstAudio = audioTrack {
                try dstAudio.insertTimeRange(clip.sourceRange, of: srcAudio, at: insertionTime)
            }

            insertionTime = CMTimeAdd(insertionTime, clip.effectiveDuration)
        }

        // Build video composition to apply correct orientation
        var videoComp: AVMutableVideoComposition? = nil

        if sourceNaturalSize != .zero {
            // Calculate render size considering transform (portrait iPhone = rotated)
            let renderSize = transformedSize(sourceNaturalSize, transform: sourceTransform)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: insertionTime)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(sourceTransform, at: .zero)
            instruction.layerInstructions = [layerInstruction]

            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.instructions = [instruction]
            videoComp = vc
        }

        return Result(composition: composition, videoComposition: videoComp, audioMix: nil)
    }

    /// Calculate the output size after applying the transform
    private static func transformedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
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
