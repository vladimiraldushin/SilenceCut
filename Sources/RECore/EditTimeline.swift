import Foundation
import CoreMedia

/// The Edit Decision List — ordered array of clips forming the edited video.
/// All timeline operations manipulate this model, then CompositionBuilder
/// rebuilds AVMutableComposition from scratch.
public struct EditTimeline: Codable, Equatable {
    public var clips: [TimelineClip]

    public init(clips: [TimelineClip] = []) {
        self.clips = clips
    }

    /// Total duration of the edited timeline (only enabled clips)
    public var duration: CMTime {
        clips.filter(\.isEnabled).reduce(CMTime.zero) { CMTimeAdd($0, $1.effectiveDuration) }
    }

    /// Number of enabled clips
    public var enabledClipCount: Int {
        clips.filter(\.isEnabled).count
    }

    // MARK: - Timeline Operations

    /// Recalculate all timelineOffsets based on clip order (ripple)
    public mutating func recalculateOffsets() {
        var offset = CMTime.zero
        for i in clips.indices {
            clips[i].timelineOffset = offset
            if clips[i].isEnabled {
                offset = CMTimeAdd(offset, clips[i].effectiveDuration)
            }
        }
    }

    /// Split a clip at a given timeline time
    public mutating func splitClip(at clipIndex: Int, splitTime: CMTime) {
        guard clipIndex >= 0 && clipIndex < clips.count else { return }
        let clip = clips[clipIndex]
        let offsetInClip = CMTimeSubtract(splitTime, clip.timelineOffset)

        // Validate split point is within the clip
        guard CMTimeCompare(offsetInClip, .zero) > 0,
              CMTimeCompare(offsetInClip, clip.effectiveDuration) < 0 else { return }

        let sourceSplitPoint = CMTimeAdd(clip.sourceRange.start, offsetInClip)

        var firstHalf = clip
        firstHalf.sourceRange = CMTimeRange(start: clip.sourceRange.start, duration: offsetInClip)

        let secondHalf = TimelineClip(
            id: UUID(),
            sourceURL: clip.sourceURL,
            availableRange: clip.availableRange,
            sourceRange: CMTimeRange(
                start: sourceSplitPoint,
                duration: CMTimeSubtract(clip.sourceRange.duration, offsetInClip)
            ),
            timelineOffset: splitTime,
            speed: clip.speed,
            isEnabled: clip.isEnabled
        )

        clips[clipIndex] = firstHalf
        clips.insert(secondHalf, at: clipIndex + 1)
        recalculateOffsets()
    }

    /// Delete a clip by index
    public mutating func deleteClip(at clipIndex: Int) {
        guard clipIndex >= 0 && clipIndex < clips.count else { return }
        clips.remove(at: clipIndex)
        recalculateOffsets()
    }

    /// Delete a clip by ID
    public mutating func deleteClip(id: UUID) {
        clips.removeAll { $0.id == id }
        recalculateOffsets()
    }

    /// Toggle a clip's enabled state
    public mutating func toggleClip(id: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[idx].isEnabled.toggle()
        recalculateOffsets()
    }

    /// Trim a clip's source range (non-destructive — can always expand back)
    public mutating func trimClip(id: UUID, newSourceRange: CMTimeRange) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        // Clamp to available range
        let clampedStart = max(
            CMTimeGetSeconds(clips[idx].availableRange.start),
            CMTimeGetSeconds(newSourceRange.start)
        )
        let clampedEnd = min(
            CMTimeGetSeconds(CMTimeRangeGetEnd(clips[idx].availableRange)),
            CMTimeGetSeconds(CMTimeRangeGetEnd(newSourceRange))
        )
        let duration = max(0.01, clampedEnd - clampedStart)
        clips[idx].sourceRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        recalculateOffsets()
    }

    /// Find clip index at a given timeline time
    public func clipIndex(at time: CMTime) -> Int? {
        for (i, clip) in clips.enumerated() where clip.isEnabled {
            if CMTimeCompare(time, clip.timelineOffset) >= 0 &&
               CMTimeCompare(time, clip.timelineEnd) < 0 {
                return i
            }
        }
        return nil
    }

    /// Create timeline from speech ranges (for silence detection)
    public static func fromSpeechRanges(_ ranges: [CMTimeRange], sourceURL: URL, availableRange: CMTimeRange) -> EditTimeline {
        var clips: [TimelineClip] = []
        var offset = CMTime.zero
        for range in ranges {
            let clip = TimelineClip(
                sourceURL: sourceURL,
                availableRange: availableRange,
                sourceRange: range,
                timelineOffset: offset
            )
            clips.append(clip)
            offset = CMTimeAdd(offset, range.duration)
        }
        return EditTimeline(clips: clips)
    }
}
