import Testing
import Foundation
import CoreGraphics
import CoreMedia
@testable import RETimeline
import RECore

private let vertical = CGSize(width: 1080, height: 1920)
private let horizontal = CGSize(width: 1920, height: 1080)

private func makeSource(size: CGSize, fps: Double = 30, name: String = "a") -> MediaSource {
    MediaSource(
        url: URL(fileURLWithPath: "/\(name).mp4"),
        duration: CMTime(seconds: 10, preferredTimescale: 600),
        naturalSize: size,
        preferredTransform: .identity,
        nominalFrameRate: fps,
        hasAudio: true
    )
}

private func makeClip(_ source: MediaSource, seconds: Double = 10) -> TimelineClip {
    TimelineClip(
        sourceID: source.id,
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
    )
}

@Test func framingScaleMultipliesFillScale() {
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: ClipFraming(scale: 1.5), zoom: 1.0
    )
    #expect(abs(t.a - 1.5) < 0.0001)
}

@Test func framingCombinesWithJumpCutZoom() {
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: ClipFraming(scale: 1.2), zoom: 1.1
    )
    #expect(abs(t.a - 1.32) < 0.0001)
}

@Test func fitScaleShowsWholeHorizontalFrameInVerticalCanvas() {
    let framing = ClipFraming(scale: ClipFraming.fitScale(orientedSize: horizontal, targetSize: vertical))
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: horizontal, targetSize: vertical,
        framing: framing, zoom: 1.0
    )
    // Кадр вписан по ширине и не вылезает по высоте
    #expect(abs(horizontal.width * t.a - vertical.width) < 0.01)
    #expect(horizontal.height * t.d <= vertical.height + 0.01)
    // Центрирован по вертикали — поля сверху и снизу одинаковые
    #expect(abs(t.ty - (vertical.height - horizontal.height * t.d) / 2) < 0.01)
}

@Test func framingOffsetShiftsInCanvasFractions() {
    let base = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: .default, zoom: 1.0
    )
    let shifted = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: ClipFraming(scale: 1.0, offset: CGPoint(x: 0.25, y: -0.1)), zoom: 1.0
    )
    #expect(abs((shifted.tx - base.tx) - vertical.width * 0.25) < 0.01)
    #expect(abs((shifted.ty - base.ty) + vertical.height * 0.1) < 0.01)
}

@Test func defaultFramingKeepsOldBehaviour() {
    // Кадрирование по умолчанию не должно менять ничего из того, что было до его появления
    let withFraming = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: horizontal, targetSize: vertical,
        framing: .default, zoom: 1.0
    )
    let expectedScale = vertical.height / horizontal.height
    #expect(abs(withFraming.a - expectedScale) < 0.0001)
    #expect(abs(withFraming.tx - (vertical.width - horizontal.width * expectedScale) / 2) < 0.01)
}

@Test func projectRenderSizeIsAlwaysEven() {
    let source = makeSource(size: CGSize(width: 1919, height: 1081))
    let timeline = EditTimeline(sources: [source], clips: [makeClip(source)])
    let size = CompositionBuilder.projectRenderSize(timeline: timeline, options: .default)
    #expect(Int(size.width) % 2 == 0)
    #expect(Int(size.height) % 2 == 0)
    #expect(size == CGSize(width: 1918, height: 1080))
}

@Test func projectRenderSizeFollowsChosenAspect() {
    let source = makeSource(size: horizontal)
    let timeline = EditTimeline(sources: [source], clips: [makeClip(source)])
    var options = RenderOptions.default
    options.outputAspect = .vertical
    #expect(CompositionBuilder.projectRenderSize(timeline: timeline, options: options) == vertical)
}

@Test func projectRenderSizeUsesFirstSpineClipForSourceAspect() {
    // При разнородных исходниках «оригинал» — это формат первого клипа хребта
    let first = makeSource(size: vertical, name: "first")
    let second = makeSource(size: horizontal, name: "second")
    let timeline = EditTimeline(sources: [first, second], clips: [makeClip(first), makeClip(second)])
    #expect(CompositionBuilder.projectRenderSize(timeline: timeline, options: .default) == vertical)
}

@Test func projectFrameRateTakesMaximumAcrossSources() {
    let a = makeSource(size: vertical, fps: 25, name: "a")
    let b = makeSource(size: vertical, fps: 50, name: "b")
    let timeline = EditTimeline(sources: [a, b], clips: [makeClip(a), makeClip(b)])
    #expect(CompositionBuilder.projectFrameRate(timeline: timeline) == 50)
}

@Test func projectFrameRateIsClampedToSaneRange() {
    let slow = makeSource(size: vertical, fps: 8, name: "slow")
    #expect(CompositionBuilder.projectFrameRate(
        timeline: EditTimeline(sources: [slow], clips: [makeClip(slow)])) == 24)

    let fast = makeSource(size: vertical, fps: 240, name: "fast")
    #expect(CompositionBuilder.projectFrameRate(
        timeline: EditTimeline(sources: [fast], clips: [makeClip(fast)])) == 60)
}

@Test func rotatedSourceOrientedSizeSwapsDimensions() {
    var source = makeSource(size: horizontal)
    source.preferredTransform = CGAffineTransform(rotationAngle: .pi / 2)
    #expect(abs(source.orientedSize.width - horizontal.height) < 0.01)
    #expect(abs(source.orientedSize.height - horizontal.width) < 0.01)
}
