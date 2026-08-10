import Testing
import Foundation
import CoreMedia
@testable import RECore

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
private func range(_ s: Double, _ d: Double) -> CMTimeRange { CMTimeRange(start: t(s), duration: t(d)) }
private let src = UUID()

private func overlay(start: Double, duration: Double, sourceStart: Double = 0) -> OverlayClip {
    OverlayClip(sourceID: src, sourceRange: range(sourceStart, duration), timelineStart: t(start))
}

private func timeline(_ overlays: [OverlayClip]) -> EditTimeline {
    var tl = EditTimeline(sources: [], clips: [
        TimelineClip(sourceID: src, availableRange: range(0, 100), sourceRange: range(0, 100))
    ], overlays: overlays)
    tl.recalculateOffsets()
    return tl
}

@Test func overlayAfterRemovalShiftsBack() {
    var tl = timeline([overlay(start: 50, duration: 5)])
    tl.applyRemovals([range(10, 4)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 46) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 5) < 0.001)
}

@Test func overlayInsideRemovalDisappears() {
    var tl = timeline([overlay(start: 11, duration: 2)])
    tl.applyRemovals([range(10, 4)])
    #expect(tl.overlays.isEmpty)
}

@Test func overlayOverlappingRemovalHeadIsTrimmed() {
    // Перебивка 12…18, вырезаем 10…14 — остаётся 4 секунды, приехавшие на 10
    var tl = timeline([overlay(start: 12, duration: 6)])
    tl.applyRemovals([range(10, 4)])
    #expect(tl.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 10) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 4) < 0.001)
    // Съели начало — исходный диапазон тоже сдвинулся на 2 секунды
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.start) - 2) < 0.001)
}

@Test func overlayOverlappingRemovalTailIsTrimmed() {
    // Перебивка 8…14, вырезаем 10…14 — остаются первые 2 секунды на месте
    var tl = timeline([overlay(start: 8, duration: 6)])
    tl.applyRemovals([range(10, 4)])
    #expect(tl.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 8) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.start)) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 2) < 0.001)
}

@Test func overlayBeforeRemovalStaysPut() {
    var tl = timeline([overlay(start: 2, duration: 3)])
    tl.applyRemovals([range(10, 4)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 2) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 3) < 0.001)
}

@Test func multipleRemovalsAccumulate() {
    var tl = timeline([overlay(start: 50, duration: 2)])
    tl.applyRemovals([range(5, 3), range(20, 7)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 40) < 0.001)
}

@Test func overlappingRemovalsAreMergedNotDoubleCounted() {
    // 10…16 и 12…20 перекрываются: суммарно вырезано 10 секунд, а не 14
    var tl = timeline([overlay(start: 50, duration: 2)])
    tl.applyRemovals([range(10, 6), range(12, 8)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 40) < 0.001)
}

@Test func removalInsideOverlaySplitsItInTwo() {
    // Перебивка 10…20, вырезаем 12…14 изнутри. Кадры b-roll, лежавшие в вырезанном куске,
    // исчезают вместе с ним — значит перебивка распадается на 10…12 и 12…18 (после сдвига).
    var tl = timeline([overlay(start: 10, duration: 10)])
    tl.applyRemovals([range(12, 2)])

    #expect(tl.overlays.count == 2)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 10) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.start)) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 2) < 0.001)

    #expect(abs(CMTimeGetSeconds(tl.overlays[1].timelineStart) - 12) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[1].sourceRange.start) - 4) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[1].sourceRange.duration) - 6) < 0.001)
    // У половинок разные id — иначе выделение и undo будут путать их между собой
    #expect(tl.overlays[0].id != tl.overlays[1].id)
}

@Test func splitClipBySpeechRangesKeepsNeighboursIntact() {
    var tl = EditTimeline(sources: [], clips: [
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
    ])
    tl.recalculateOffsets()
    let firstID = tl.clips[0].id
    tl.splitClipBySpeechRanges(clipID: firstID, speechRanges: [range(0, 3), range(7, 3)])

    #expect(tl.clips.count == 3)
    #expect(abs(CMTimeGetSeconds(tl.duration) - 16) < 0.001)
    // Второй клип не тронут
    #expect(abs(CMTimeGetSeconds(tl.clips[2].sourceRange.duration) - 10) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.clips[2].timelineOffset) - 6) < 0.001)
}

@Test func splitClipBySpeechRangesRipplesOverlays() {
    // Клип 0…10, речь 0…3 и 7…10 — вырезаны 4 секунды в середине.
    // Перебивка, стоявшая на 12, должна приехать на 8.
    var tl = EditTimeline(sources: [], clips: [
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
    ], overlays: [overlay(start: 12, duration: 2)])
    tl.recalculateOffsets()
    let firstID = tl.clips[0].id
    tl.splitClipBySpeechRanges(clipID: firstID, speechRanges: [range(0, 3), range(7, 3)])

    #expect(tl.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 8) < 0.001)
}

@Test func splitClipBySpeechRangesWithNoSpeechRemovesClip() {
    var tl = EditTimeline(sources: [], clips: [
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 5)),
    ])
    tl.recalculateOffsets()
    let firstID = tl.clips[0].id
    tl.splitClipBySpeechRanges(clipID: firstID, speechRanges: [])

    #expect(tl.clips.count == 1)
    #expect(abs(CMTimeGetSeconds(tl.duration) - 5) < 0.001)
}

@Test func overlaysBeyondTimelineEndAreClamped() {
    var tl = timeline([overlay(start: 98, duration: 5)])
    #expect(abs(CMTimeGetSeconds(tl.clampedOverlays[0].sourceRange.duration) - 2) < 0.001)

    tl.overlays = [overlay(start: 120, duration: 5)]
    #expect(tl.clampedOverlays.isEmpty)
}

@Test func timelineWithOverlaysRoundTripsThroughJSON() throws {
    let tl = timeline([overlay(start: 5, duration: 3)])
    let data = try JSONEncoder().encode(tl)
    let decoded = try JSONDecoder().decode(EditTimeline.self, from: data)
    #expect(decoded.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(decoded.overlays[0].timelineStart) - 5) < 0.001)
    #expect(decoded.overlays[0].framing == .default)
}
