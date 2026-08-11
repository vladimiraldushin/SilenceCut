import Testing
import Foundation
import CoreMedia
@testable import RECore

// Удаление, выключение и подрезка клипа тоже укорачивают таймлайн — значит обязаны
// тащить за собой перебивки и графику. Раньше они этого не делали: клип исчезал,
// а титр оставался на прежней секунде и показывался поверх уже другого материала.

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
private func range(_ s: Double, _ d: Double) -> CMTimeRange { CMTimeRange(start: t(s), duration: t(d)) }

private let source = UUID()

private func spine(_ durations: [Double], graphicAt: Double? = nil, graphicLength: Double = 2)
    -> EditTimeline
{
    var timeline = EditTimeline(
        sources: [],
        clips: durations.map {
            TimelineClip(sourceID: source, availableRange: range(0, 600), sourceRange: range(0, $0))
        },
        graphics: graphicAt.map {
            [GraphicClip(sourceID: source, sourceRange: range(0, graphicLength), timelineStart: t($0))]
        } ?? []
    )
    timeline.recalculateOffsets()
    return timeline
}

// MARK: - Удаление клипа

@Test func deletingClipPullsLaterGraphicBack() {
    // Клипы 10+10+10, титр на 25-й; удаляем первый — титр обязан уехать на 15-ю
    var timeline = spine([10, 10, 10], graphicAt: 25)
    timeline.deleteClip(id: timeline.clips[0].id)

    #expect(timeline.clips.count == 2)
    #expect(abs(CMTimeGetSeconds(timeline.duration) - 20) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 15) < 0.001)
}

@Test func deletingClipRemovesGraphicOverIt() {
    var timeline = spine([10, 10], graphicAt: 2)
    timeline.deleteClip(id: timeline.clips[0].id)
    #expect(timeline.graphics.isEmpty)
}

@Test func deletingDisabledClipDoesNotMoveGraphics() {
    // Выключенный клип уже не занимает места на таймлайне
    var timeline = spine([10, 10], graphicAt: 12)
    timeline.clips[0].isEnabled = false
    timeline.recalculateOffsets()

    timeline.deleteClip(id: timeline.clips[0].id)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 12) < 0.001)
}

// MARK: - Выключение клипа

@Test func disablingClipPullsLaterGraphicBack() {
    var timeline = spine([10, 10, 10], graphicAt: 25)
    timeline.toggleClip(id: timeline.clips[0].id)

    #expect(abs(CMTimeGetSeconds(timeline.duration) - 20) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 15) < 0.001)
}

@Test func reenablingClipPushesGraphicForwardAgain() {
    // Выключили и включили обратно — титр обязан вернуться на исходную секунду
    var timeline = spine([10, 10, 10], graphicAt: 25)
    let id = timeline.clips[0].id

    timeline.toggleClip(id: id)
    timeline.toggleClip(id: id)

    #expect(abs(CMTimeGetSeconds(timeline.duration) - 30) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 25) < 0.001)
}

// MARK: - Подрезка клипа

@Test func trimmingTailPullsLaterGraphicBack() {
    var timeline = spine([10, 10], graphicAt: 15)
    // Первый клип с 10 до 6 секунд, режем с конца
    timeline.trimClip(id: timeline.clips[0].id, newSourceRange: range(0, 6))

    #expect(abs(CMTimeGetSeconds(timeline.duration) - 16) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 11) < 0.001)
}

@Test func trimmingHeadPullsLaterGraphicBack() {
    var timeline = spine([10, 10], graphicAt: 15)
    // Сдвигаем начало первого клипа на 4 секунды вперёд
    timeline.trimClip(id: timeline.clips[0].id, newSourceRange: range(4, 6))

    #expect(abs(CMTimeGetSeconds(timeline.duration) - 16) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 11) < 0.001)
}

@Test func trimmingHeadCutsGraphicSittingInTheRemovedPart() {
    // Титр стоял на 1-й секунде — ровно в куске, который срезали с головы клипа
    var timeline = spine([10, 10], graphicAt: 1, graphicLength: 2)
    timeline.trimClip(id: timeline.clips[0].id, newSourceRange: range(4, 6))
    #expect(timeline.graphics.isEmpty)
}

@Test func growingClipBackPushesGraphicForward() {
    var timeline = spine([10, 10], graphicAt: 15)
    let id = timeline.clips[0].id
    timeline.trimClip(id: id, newSourceRange: range(0, 6))
    timeline.trimClip(id: id, newSourceRange: range(0, 10))

    #expect(abs(CMTimeGetSeconds(timeline.duration) - 20) < 0.001)
    #expect(abs(CMTimeGetSeconds(timeline.graphics[0].timelineStart) - 15) < 0.001)
}

@Test func trimBeyondAvailableRangeIsClamped() {
    var timeline = spine([10])
    timeline.trimClip(id: timeline.clips[0].id, newSourceRange: range(0, 9999))
    #expect(CMTimeGetSeconds(timeline.clips[0].sourceRange.duration) <= 600.001)
}
