import Testing
import Foundation
import CoreMedia
import CoreGraphics
@testable import RECore

private func makeSource(_ name: String) -> MediaSource {
    MediaSource(
        url: URL(fileURLWithPath: "/\(name).mp4"),
        duration: CMTime(seconds: 60, preferredTimescale: 600),
        naturalSize: CGSize(width: 1920, height: 1080),
        preferredTransform: .identity,
        nominalFrameRate: 30,
        hasAudio: true
    )
}

@Test func timelineFindsSourceByID() {
    let a = makeSource("a"), b = makeSource("b")
    let timeline = EditTimeline(sources: [a, b], clips: [])
    #expect(timeline.source(for: b.id)?.url.lastPathComponent == "b.mp4")
    #expect(timeline.source(for: UUID()) == nil)
}

@Test func timelineWithTwoSourcesRoundTripsThroughJSON() throws {
    let a = makeSource("a"), b = makeSource("b")
    let clip = TimelineClip(
        sourceID: a.id,
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 60, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
    )
    let timeline = EditTimeline(sources: [a, b], clips: [clip])
    let data = try JSONEncoder().encode(timeline)
    let decoded = try JSONDecoder().decode(EditTimeline.self, from: data)
    #expect(decoded.sources.count == 2)
    #expect(decoded.clips.first?.sourceID == a.id)
    #expect(decoded.clips.first?.framing == .default)
}

@Test func mediaSourceKeepsTransformAndSizeThroughJSON() throws {
    var source = makeSource("rotated")
    source.preferredTransform = CGAffineTransform(rotationAngle: .pi / 2)
    source.naturalSize = CGSize(width: 1080, height: 1920)
    source.integratedLUFS = -18.5
    source.gain = 1.35

    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode(MediaSource.self, from: data)

    #expect(decoded.naturalSize == CGSize(width: 1080, height: 1920))
    #expect(abs(decoded.preferredTransform.b - 1) < 0.0001)
    #expect(abs(decoded.preferredTransform.c + 1) < 0.0001)
    #expect(decoded.integratedLUFS == -18.5)
    #expect(abs(decoded.gain - 1.35) < 0.0001)
}

@Test func defaultFramingIsFullFrame() {
    #expect(ClipFraming.default.scale == 1.0)
    #expect(ClipFraming.default.offset == .zero)
}

@Test func framingDecodesFromEmptyObject() throws {
    // Снимки, сохранённые до появления кадрирования, читаются как значение по умолчанию
    let decoded = try JSONDecoder().decode(ClipFraming.self, from: Data("{}".utf8))
    #expect(decoded == .default)
}

@Test func splitClipKeepsSourceAndFraming() {
    let source = makeSource("a")
    var clip = TimelineClip(
        sourceID: source.id,
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
    )
    clip.framing = ClipFraming(scale: 1.4, offset: CGPoint(x: 0.1, y: -0.2))

    var timeline = EditTimeline(sources: [source], clips: [clip])
    timeline.recalculateOffsets()
    timeline.splitClip(at: 0, splitTime: CMTime(seconds: 4, preferredTimescale: 600))

    #expect(timeline.clips.count == 2)
    #expect(timeline.clips.allSatisfy { $0.sourceID == source.id })
    #expect(timeline.clips.allSatisfy { $0.framing == clip.framing })
}
