import Foundation
import CoreMedia

/// A clip on the timeline — the fundamental unit of non-destructive editing.
/// Stores source reference and trim points. The source file is NEVER modified.
public struct TimelineClip: Identifiable, Codable, Equatable {
    public let id: UUID
    public let sourceURL: URL

    /// Full range of the source media (never changes — enables non-destructive trim)
    public let availableRange: CMTimeRange

    /// Current trimmed range within the source (user can expand back to availableRange)
    public var sourceRange: CMTimeRange

    /// Position on the output timeline
    public var timelineOffset: CMTime

    /// Playback speed multiplier
    public var speed: Double = 1.0

    /// Whether this clip is included in the output
    public var isEnabled: Bool = true

    /// Duration on the timeline (accounting for speed)
    public var effectiveDuration: CMTime {
        CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1.0 / speed)
    }

    /// End time on the timeline
    public var timelineEnd: CMTime {
        CMTimeAdd(timelineOffset, effectiveDuration)
    }

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        availableRange: CMTimeRange,
        sourceRange: CMTimeRange,
        timelineOffset: CMTime = .zero,
        speed: Double = 1.0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.availableRange = availableRange
        self.sourceRange = sourceRange
        self.timelineOffset = timelineOffset
        self.speed = speed
        self.isEnabled = isEnabled
    }
}

// MARK: - Codable conformance for CMTime/CMTimeRange

extension CMTime: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case value, timescale }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(Int64.self, forKey: .value)
        let timescale = try c.decode(Int32.self, forKey: .timescale)
        self = CMTime(value: value, timescale: timescale)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.value, forKey: .value)
        try c.encode(self.timescale, forKey: .timescale)
    }
}

extension CMTimeRange: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case start, duration }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(CMTime.self, forKey: .start)
        let duration = try c.decode(CMTime.self, forKey: .duration)
        self = CMTimeRange(start: start, duration: duration)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.start, forKey: .start)
        try c.encode(self.duration, forKey: .duration)
    }
}
