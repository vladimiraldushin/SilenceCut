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
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BuildError.cannotCreateTrack }

        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertionTime = CMTime.zero

        for clip in timeline.clips where clip.isEnabled {
            let asset = AVURLAsset(url: clip.sourceURL)

            // Insert video
            if let srcVideo = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(clip.sourceRange, of: srcVideo, at: insertionTime)

                // Preserve video orientation
                let transform = try await srcVideo.load(.preferredTransform)
                videoTrack.preferredTransform = transform
            }

            // Insert audio
            if let srcAudio = try await asset.loadTracks(withMediaType: .audio).first,
               let dstAudio = audioTrack {
                try dstAudio.insertTimeRange(clip.sourceRange, of: srcAudio, at: insertionTime)
            }

            insertionTime = CMTimeAdd(insertionTime, clip.effectiveDuration)
        }

        return Result(composition: composition, videoComposition: nil, audioMix: nil)
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
