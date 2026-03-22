import Foundation
import CoreMedia

/// Represents a single fragment on the timeline (either speech or silence)
struct TimelineFragment: Identifiable, Codable, Equatable {
    let id: UUID
    /// Time range in the source video
    var sourceStartTime: Double  // seconds
    var sourceDuration: Double   // seconds
    /// Fragment classification
    var type: FragmentType
    /// Whether this fragment is included in the final export
    var isIncluded: Bool

    var sourceEndTime: Double {
        sourceStartTime + sourceDuration
    }

    /// CMTimeRange for AVFoundation operations
    var cmTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: sourceStartTime, preferredTimescale: 600),
            duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)
        )
    }

    init(
        id: UUID = UUID(),
        sourceStartTime: Double,
        sourceDuration: Double,
        type: FragmentType,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.sourceStartTime = sourceStartTime
        self.sourceDuration = sourceDuration
        self.type = type
        self.isIncluded = isIncluded
    }
}

enum FragmentType: String, Codable {
    case speech
    case silence
}
