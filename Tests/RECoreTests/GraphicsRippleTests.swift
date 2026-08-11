import Testing
import Foundation
import CoreMedia
@testable import RECore

// Графика приколота ко времени таймлайна так же, как перебивка, и обязана ехать за
// хребтом при любом вырезе и вставке. Риппл у них общий (`PinnedClip`), эти тесты его и
// сторожат: если кто-то разведёт поведение слоёв, здесь станет видно.

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
private func range(_ s: Double, _ d: Double) -> CMTimeRange { CMTimeRange(start: t(s), duration: t(d)) }

private let spineSource = UUID()
private let graphicSource = UUID()

private func graphic(start: Double, duration: Double, sourceStart: Double = 0) -> GraphicClip {
    GraphicClip(
        sourceID: graphicSource,
        sourceRange: range(sourceStart, duration),
        timelineStart: t(start)
    )
}

private func timeline(spineSeconds: Double, graphics: [GraphicClip]) -> EditTimeline {
    var result = EditTimeline(
        sources: [],
        clips: [TimelineClip(
            sourceID: spineSource,
            availableRange: range(0, 600),
            sourceRange: range(0, spineSeconds)
        )],
        overlays: [],
        graphics: graphics
    )
    result.recalculateOffsets()
    return result
}

// MARK: - Вырез

@Test func cutBeforeGraphicMovesItBack() {
    var edit = timeline(spineSeconds: 30, graphics: [graphic(start: 20, duration: 3)])
    edit.applyRemovals([range(5, 4)])

    #expect(edit.graphics.count == 1)
    #expect(abs(CMTimeGetSeconds(edit.graphics[0].timelineStart) - 16) < 0.001)
    #expect(abs(CMTimeGetSeconds(edit.graphics[0].sourceRange.duration) - 3) < 0.001)
}

@Test func cutInsideGraphicSplitsIt() {
    var edit = timeline(spineSeconds: 30, graphics: [graphic(start: 10, duration: 6)])
    edit.applyRemovals([range(12, 2)])

    #expect(edit.graphics.count == 2)
    #expect(abs(CMTimeGetSeconds(edit.graphics[0].timelineStart) - 10) < 0.001)
    #expect(abs(CMTimeGetSeconds(edit.graphics[0].sourceRange.duration) - 2) < 0.001)
    #expect(abs(CMTimeGetSeconds(edit.graphics[1].timelineStart) - 12) < 0.001)
    #expect(abs(CMTimeGetSeconds(edit.graphics[1].sourceRange.duration) - 2) < 0.001)
}

@Test func cutSwallowingGraphicRemovesIt() {
    var edit = timeline(spineSeconds: 30, graphics: [graphic(start: 10, duration: 2)])
    edit.applyRemovals([range(8, 6)])
    #expect(edit.graphics.isEmpty)
}

@Test func graphicKeepsIdentityOnFirstSurvivingPiece() {
    // Выделение и undo не должны терять титр из-за того, что его подрезали
    let original = graphic(start: 10, duration: 6)
    var edit = timeline(spineSeconds: 30, graphics: [original])
    edit.applyRemovals([range(14, 1)])

    #expect(edit.graphics.first?.id == original.id)
}

@Test func graphicOriginSurvivesSplit() {
    // Родословная нужна для перерисовки — она обязана пережить разрез
    var withOrigin = graphic(start: 10, duration: 6)
    withOrigin.origin = GraphicOrigin(
        template: "LowerThird", propsJSON: #"{"title":"Тест"}"#, packVersion: "1"
    )
    var edit = timeline(spineSeconds: 30, graphics: [withOrigin])
    edit.applyRemovals([range(12, 2)])

    #expect(edit.graphics.count == 2)
    #expect(edit.graphics.allSatisfy { $0.origin?.template == "LowerThird" })
}

// MARK: - Вставка

@Test func insertShiftsLaterGraphic() {
    var edit = timeline(spineSeconds: 30, graphics: [graphic(start: 20, duration: 3)])
    let clip = TimelineClip(sourceID: spineSource, availableRange: range(0, 600), sourceRange: range(0, 5))
    edit.insertClip(clip, at: t(10))

    #expect(abs(CMTimeGetSeconds(edit.graphics[0].timelineStart) - 25) < 0.001)
}

@Test func insertInsideGraphicSplitsIt() {
    var edit = timeline(spineSeconds: 30, graphics: [graphic(start: 8, duration: 6)])
    let clip = TimelineClip(sourceID: spineSource, availableRange: range(0, 600), sourceRange: range(0, 5))
    edit.insertClip(clip, at: t(10))

    #expect(edit.graphics.count == 2)
    #expect(abs(CMTimeGetSeconds(edit.graphics[0].sourceRange.duration) - 2) < 0.001)
    #expect(abs(CMTimeGetSeconds(edit.graphics[1].timelineStart) - 15) < 0.001)
}

// MARK: - Слои двигаются вместе

@Test func cutMovesOverlayAndGraphicIdentically() {
    // Титр над перебивкой обязан остаться над ней после выреза, а не уехать в сторону
    var edit = EditTimeline(
        sources: [],
        clips: [TimelineClip(
            sourceID: spineSource, availableRange: range(0, 600), sourceRange: range(0, 30)
        )],
        overlays: [OverlayClip(
            sourceID: graphicSource, sourceRange: range(0, 4), timelineStart: t(20)
        )],
        graphics: [graphic(start: 20, duration: 4)]
    )
    edit.recalculateOffsets()
    edit.applyRemovals([range(5, 3)])

    let overlayStart = CMTimeGetSeconds(edit.overlays[0].timelineStart)
    let graphicStart = CMTimeGetSeconds(edit.graphics[0].timelineStart)
    #expect(abs(overlayStart - graphicStart) < 0.001)
    #expect(abs(graphicStart - 17) < 0.001)
}

// MARK: - Подрезка по концу хребта

@Test func graphicPastSpineEndIsClamped() {
    let edit = timeline(spineSeconds: 10, graphics: [graphic(start: 8, duration: 5)])
    let clamped = edit.clampedGraphics

    #expect(clamped.count == 1)
    #expect(abs(CMTimeGetSeconds(clamped[0].sourceRange.duration) - 2) < 0.001)
}

@Test func graphicFullyPastSpineEndIsDropped() {
    let edit = timeline(spineSeconds: 10, graphics: [graphic(start: 12, duration: 3)])
    #expect(edit.clampedGraphics.isEmpty)
}

@Test func disabledGraphicIsNotBuilt() {
    var disabled = graphic(start: 2, duration: 3)
    disabled.isEnabled = false
    let edit = timeline(spineSeconds: 10, graphics: [disabled])
    #expect(edit.clampedGraphics.isEmpty)
}

// MARK: - Сериализация

@Test func graphicsSurviveRoundTrip() throws {
    var withOrigin = graphic(start: 4, duration: 2)
    withOrigin.origin = GraphicOrigin(
        template: "LowerThird",
        propsJSON: #"{"title":"Как открыть ИП","subtitle":"за 3 дня"}"#,
        packVersion: "0.1.0"
    )
    let edit = timeline(spineSeconds: 20, graphics: [withOrigin])

    let data = try JSONEncoder().encode(edit)
    let decoded = try JSONDecoder().decode(EditTimeline.self, from: data)

    #expect(decoded.graphics.count == 1)
    #expect(decoded.graphics[0].origin?.template == "LowerThird")
    #expect(decoded.graphics[0].origin?.packVersion == "0.1.0")
    #expect(abs(CMTimeGetSeconds(decoded.graphics[0].timelineStart) - 4) < 0.001)
}

@Test func projectWithoutGraphicsKeyStillDecodes() throws {
    // Проекты, сохранённые до появления слоя графики, обязаны открываться
    let json = #"{"sources":[],"clips":[],"overlays":[]}"#
    let decoded = try JSONDecoder().decode(EditTimeline.self, from: Data(json.utf8))
    #expect(decoded.graphics.isEmpty)
}
