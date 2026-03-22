import Testing
import CoreMedia
@testable import RECore

@Test func clipEffectiveDuration() {
    let clip = TimelineClip(
        sourceURL: URL(fileURLWithPath: "/test.mp4"),
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
    )
    #expect(CMTimeGetSeconds(clip.effectiveDuration) == 10.0)
}

@Test func clipEffectiveDurationWithSpeed() {
    let clip = TimelineClip(
        sourceURL: URL(fileURLWithPath: "/test.mp4"),
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
        speed: 2.0
    )
    #expect(CMTimeGetSeconds(clip.effectiveDuration) == 5.0)
}

@Test func timelineDuration() {
    let clips = [
        TimelineClip(
            sourceURL: URL(fileURLWithPath: "/test.mp4"),
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        ),
        TimelineClip(
            sourceURL: URL(fileURLWithPath: "/test.mp4"),
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 600), duration: CMTime(seconds: 3, preferredTimescale: 600))
        ),
    ]
    let timeline = EditTimeline(clips: clips)
    #expect(CMTimeGetSeconds(timeline.duration) == 8.0)
}

@Test func timelineSplit() {
    var timeline = EditTimeline(clips: [
        TimelineClip(
            sourceURL: URL(fileURLWithPath: "/test.mp4"),
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
        ),
    ])
    timeline.recalculateOffsets()

    timeline.splitClip(at: 0, splitTime: CMTime(seconds: 4, preferredTimescale: 600))

    #expect(timeline.clips.count == 2)
    #expect(CMTimeGetSeconds(timeline.clips[0].sourceRange.duration) == 4.0)
    #expect(CMTimeGetSeconds(timeline.clips[1].sourceRange.duration) == 6.0)
    #expect(CMTimeGetSeconds(timeline.clips[1].sourceRange.start) == 4.0)
}

@Test func timelineDelete() {
    var timeline = EditTimeline(clips: [
        TimelineClip(
            sourceURL: URL(fileURLWithPath: "/a.mp4"),
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
        ),
        TimelineClip(
            sourceURL: URL(fileURLWithPath: "/b.mp4"),
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        ),
    ])
    timeline.recalculateOffsets()

    let idToDelete = timeline.clips[0].id
    timeline.deleteClip(id: idToDelete)

    #expect(timeline.clips.count == 1)
    #expect(CMTimeGetSeconds(timeline.clips[0].timelineOffset) == 0.0)
    #expect(CMTimeGetSeconds(timeline.duration) == 3.0)
}

@Test func timelineToggle() {
    var timeline = EditTimeline(clips: [
        TimelineClip(
            sourceURL: URL(fileURLWithPath: "/test.mp4"),
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
        ),
    ])
    let id = timeline.clips[0].id

    timeline.toggleClip(id: id)
    #expect(!timeline.clips[0].isEnabled)
    #expect(CMTimeGetSeconds(timeline.duration) == 0.0)

    timeline.toggleClip(id: id)
    #expect(timeline.clips[0].isEnabled)
    #expect(CMTimeGetSeconds(timeline.duration) == 10.0)
}

@Test func timelineFromSpeechRanges() {
    let ranges = [
        CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 3, preferredTimescale: 600)),
        CMTimeRange(start: CMTime(seconds: 8, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600)),
    ]
    let url = URL(fileURLWithPath: "/test.mp4")
    let available = CMTimeRange(start: .zero, duration: CMTime(seconds: 15, preferredTimescale: 600))

    let timeline = EditTimeline.fromSpeechRanges(ranges, sourceURL: url, availableRange: available)

    #expect(timeline.clips.count == 2)
    #expect(CMTimeGetSeconds(timeline.duration) == 5.0) // 3 + 2
    #expect(CMTimeGetSeconds(timeline.clips[1].timelineOffset) == 3.0)
}

@Test func clipCodable() throws {
    let clip = TimelineClip(
        sourceURL: URL(fileURLWithPath: "/test.mp4"),
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 5, preferredTimescale: 600))
    )

    let data = try JSONEncoder().encode(clip)
    let decoded = try JSONDecoder().decode(TimelineClip.self, from: data)

    #expect(decoded.id == clip.id)
    #expect(CMTimeGetSeconds(decoded.sourceRange.start) == 2.0)
    #expect(CMTimeGetSeconds(decoded.sourceRange.duration) == 5.0)
}
