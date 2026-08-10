import Testing
import Foundation
import CoreMedia
@testable import RECore

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
private func range(_ s: Double, _ d: Double) -> CMTimeRange { CMTimeRange(start: t(s), duration: t(d)) }

private let srcA = UUID()
private let srcB = UUID()

private func clip(_ source: UUID, _ duration: Double) -> TimelineClip {
    TimelineClip(sourceID: source, availableRange: range(0, 100), sourceRange: range(0, duration))
}

private func overlay(start: Double, duration: Double) -> OverlayClip {
    OverlayClip(sourceID: srcB, sourceRange: range(0, duration), timelineStart: t(start))
}

private func spine(_ durations: [Double], overlays: [OverlayClip] = []) -> EditTimeline {
    var timeline = EditTimeline(
        sources: [], clips: durations.map { clip(srcA, $0) }, overlays: overlays
    )
    timeline.recalculateOffsets()
    return timeline
}

// MARK: - Вставка

@Test func insertAtClipBoundaryAddsClipWithoutSplitting() {
    var timeline = spine([10, 10])
    timeline.insertClip(clip(srcB, 4), at: t(10))

    #expect(timeline.clips.count == 3)
    #expect(timeline.clips[1].sourceID == srcB)
    #expect(abs(CMTimeGetSeconds(timeline.duration) - 24) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.clips[2].timelineOffset) - 14) < 0.001)
}

@Test func insertInsideClipSplitsIt() {
    var timeline = spine([10])
    timeline.insertClip(clip(srcB, 4), at: t(6))

    // 0…6 хребта, 6…10 вставка, 10…14 остаток хребта
    #expect(timeline.clips.count == 3)
    #expect(abs(CMTimeGetSeconds(timeline.clips[0].effectiveDuration) - 6) < 0.001)
    #expect(timeline.clips[1].sourceID == srcB)
    #expect(abs(CMTimeGetSeconds(timeline.clips[1].effectiveDuration) - 4) < 0.001)
    #expect(timeline.clips[2].sourceID == srcA)
    #expect(abs(CMTimeGetSeconds(timeline.clips[2].effectiveDuration) - 4) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.duration) - 14) < 0.001)
}

@Test func insertAtStartPutsClipFirst() {
    var timeline = spine([10])
    timeline.insertClip(clip(srcB, 3), at: .zero)

    #expect(timeline.clips.count == 2)
    #expect(timeline.clips[0].sourceID == srcB)
    #expect(abs(CMTimeGetSeconds(timeline.clips[1].timelineOffset) - 3) < 0.001)
}

@Test func insertAtEndAppends() {
    var timeline = spine([10])
    timeline.insertClip(clip(srcB, 3), at: t(10))

    #expect(timeline.clips.count == 2)
    #expect(timeline.clips[1].sourceID == srcB)
    #expect(abs(CMTimeGetSeconds(timeline.duration) - 13) < 0.001)
}

@Test func insertBeyondEndClampsToEnd() {
    var timeline = spine([10])
    timeline.insertClip(clip(srcB, 3), at: t(999))

    #expect(timeline.clips.count == 2)
    #expect(abs(CMTimeGetSeconds(timeline.duration) - 13) < 0.001)
}

@Test func insertShiftsOverlaysAfterIt() {
    var timeline = spine([20], overlays: [overlay(start: 15, duration: 2)])
    timeline.insertClip(clip(srcB, 5), at: t(10))

    #expect(timeline.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[0].timelineStart) - 20) < 0.001)
}

@Test func insertLeavesEarlierOverlaysAlone() {
    var timeline = spine([20], overlays: [overlay(start: 2, duration: 3)])
    timeline.insertClip(clip(srcB, 5), at: t(10))

    #expect(abs(CMTimeGetSeconds(timeline.overlays[0].timelineStart) - 2) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[0].sourceRange.duration) - 3) < 0.001)
}

@Test func insertInsideOverlaySplitsIt() {
    // Перебивка 8…14, вставляем 5 секунд на 10: кадры перебивки не должны накрыть
    // новый материал, поэтому она распадается на 8…10 и 15…19
    var timeline = spine([20], overlays: [overlay(start: 8, duration: 6)])
    timeline.insertClip(clip(srcB, 5), at: t(10))

    #expect(timeline.overlays.count == 2)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[0].timelineStart) - 8) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[0].sourceRange.duration) - 2) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[1].timelineStart) - 15) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[1].sourceRange.duration) - 4) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[1].sourceRange.start) - 2) < 0.001)
}

// MARK: - Перестановка

@Test func moveClipForwardReordersSpine() {
    var timeline = spine([5, 3, 7])
    let first = timeline.clips[0].id
    timeline.moveClip(id: first, toBoundary: 3)   // к последнему стыку — в самый конец

    #expect(abs(CMTimeGetSeconds(timeline.clips[0].effectiveDuration) - 3) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.clips[1].effectiveDuration) - 7) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.clips[2].effectiveDuration) - 5) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.clips[2].timelineOffset) - 10) < 0.001)
}

@Test func moveClipBackwardReordersSpine() {
    var timeline = spine([5, 3, 7])
    let last = timeline.clips[2].id
    timeline.moveClip(id: last, toBoundary: 0)

    #expect(abs(CMTimeGetSeconds(timeline.clips[0].effectiveDuration) - 7) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.clips[1].effectiveDuration) - 5) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.clips[2].effectiveDuration) - 3) < 0.001)
}

@Test func moveClipKeepsTotalDurationAndOverlays() {
    // Перебивки приколоты ко времени таймлайна, а его общая длина от перестановки
    // не меняется — значит они остаются на своих местах
    var timeline = spine([5, 3, 7], overlays: [overlay(start: 6, duration: 2)])
    let first = timeline.clips[0].id
    timeline.moveClip(id: first, toBoundary: 3)

    #expect(abs(CMTimeGetSeconds(timeline.duration) - 15) < 0.001)
    #expect(timeline.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(timeline.overlays[0].timelineStart) - 6) < 0.001)
}

@Test func moveClipToSamePositionChangesNothing() {
    var timeline = spine([5, 3, 7])
    let before = timeline.clips.map(\.id)
    timeline.moveClip(id: timeline.clips[1].id, toBoundary: 1)
    #expect(timeline.clips.map(\.id) == before)
}

@Test func moveClipWithUnknownIDIsIgnored() {
    var timeline = spine([5, 3])
    let before = timeline.clips.map(\.id)
    timeline.moveClip(id: UUID(), toBoundary: 0)
    #expect(timeline.clips.map(\.id) == before)
}

@Test func insertIndexForTimeSnapsToNearestBoundary() {
    let timeline = spine([5, 3, 7])
    // Ближе к началу второго клипа, чем к концу первого
    #expect(timeline.insertIndex(atTimelineTime: t(5.4)) == 1)
    #expect(timeline.insertIndex(atTimelineTime: t(0.1)) == 0)
    #expect(timeline.insertIndex(atTimelineTime: t(14.9)) == 3)
}
