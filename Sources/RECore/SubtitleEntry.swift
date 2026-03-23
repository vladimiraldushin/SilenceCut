import Foundation
import CoreMedia

/// A single subtitle segment with word-level timings for karaoke rendering.
/// All times are in SOURCE video time (not edited timeline time).
/// Use EditTimeline.timelineTime(forSourceTime:) to map to timeline.
public struct SubtitleEntry: Identifiable, Codable, Equatable {
    public let id: UUID
    public var text: String
    public var startTime: CMTime       // source video time
    public var endTime: CMTime         // source video time
    public var words: [WordTiming]

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: CMTime,
        endTime: CMTime,
        words: [WordTiming] = []
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
    }

    public var duration: CMTime {
        CMTimeSubtract(endTime, startTime)
    }
}

/// Word-level timing for karaoke-style subtitle rendering
public struct WordTiming: Codable, Equatable, Identifiable {
    public let id: UUID
    public var word: String
    public var startTime: CMTime       // source video time
    public var endTime: CMTime         // source video time

    public init(
        id: UUID = UUID(),
        word: String,
        startTime: CMTime,
        endTime: CMTime
    ) {
        self.id = id
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
    }
}
