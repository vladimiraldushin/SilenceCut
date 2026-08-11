import Testing
import Foundation
import CoreMedia
@testable import RECore

// У TimelineClip свой encode(to:), и добавленное поле в нём легко забыть. Тогда правка
// молча теряется при сохранении: команда рапортует об успехе, проект остаётся прежним.
// Ровно так пропали gain и framingEnd. Этот тест сверяет клип целиком, а не по полям.

private func range(_ s: Double, _ d: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                duration: CMTime(seconds: d, preferredTimescale: 600))
}

@Test func clipSurvivesRoundTripWithEveryField() throws {
    var clip = TimelineClip(
        sourceID: UUID(),
        availableRange: range(0, 100),
        sourceRange: range(3, 7),
        timelineOffset: CMTime(seconds: 12, preferredTimescale: 600),
        speed: 1.25,
        isEnabled: false,
        framing: ClipFraming(scale: 1.5, offset: CGPoint(x: -0.26, y: 0.1)),
        framingEnd: ClipFraming(scale: 2.1, offset: CGPoint(x: -0.16, y: 0.14)),
        gain: 3.75
    )
    clip.legacySourceURL = nil

    let data = try JSONEncoder().encode(clip)
    let back = try JSONDecoder().decode(TimelineClip.self, from: data)

    #expect(back == clip)
    // Отдельно то, что уже терялось: равенство структур могло бы пройти и на умолчаниях
    #expect(abs(back.gain - 3.75) < 0.0001)
    #expect(abs((back.framingEnd?.scale ?? 0) - 2.1) < 0.0001)
    #expect(abs((back.framingEnd?.offset.x ?? 0) - (-0.16)) < 0.0001)
}

@Test func clipWithoutOptionalFieldsStillDecodes() throws {
    // Проекты, сохранённые до появления полей, обязаны открываться
    let json = """
    {"id":"\(UUID().uuidString)","sourceID":"\(UUID().uuidString)",
     "availableRange":{"start":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600}},
     "sourceRange":{"start":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600}},
     "timelineOffset":{"value":0,"timescale":600},"speed":1,"isEnabled":true}
    """
    let clip = try JSONDecoder().decode(TimelineClip.self, from: Data(json.utf8))
    #expect(abs(clip.gain - 1.0) < 0.0001)
    #expect(clip.framingEnd == nil)
    #expect(clip.framing == .default)
}
