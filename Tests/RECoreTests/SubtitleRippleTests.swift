import Testing
import Foundation
import CoreMedia
@testable import RECore

// Субтитры лежат во времени таймлайна, поэтому обязаны ехать за монтажом так же, как
// перебивки и титры. Раньше приложение при любой правке просто стирало расшифровку —
// эти тесты сторожат, что вместо этого она теперь сдвигается.

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
private func range(_ s: Double, _ d: Double) -> CMTimeRange { CMTimeRange(start: t(s), duration: t(d)) }

private func entry(_ text: String, _ start: Double, _ end: Double, words: [(String, Double, Double)] = []) -> SubtitleEntry {
    SubtitleEntry(
        text: text,
        startTime: t(start),
        endTime: t(end),
        words: words.map { WordTiming(word: $0.0, startTime: t($0.1), endTime: t($0.2)) }
    )
}

// MARK: - Вставка

@Test func insertAtStartShiftsEverything() {
    // Заставка в начало: вся речь уезжает вправо ровно на её длину
    let entries = [entry("первая", 1, 2), entry("вторая", 5, 6)]
    let result = SubtitleRipple.applyInsertion(to: entries, at: .zero, duration: t(4))

    #expect(abs(CMTimeGetSeconds(result[0].startTime) - 5) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[0].endTime) - 6) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[1].startTime) - 9) < 0.001)
}

@Test func insertLeavesEarlierSubtitlesAlone() {
    let entries = [entry("до", 1, 2), entry("после", 20, 21)]
    let result = SubtitleRipple.applyInsertion(to: entries, at: t(10), duration: t(3))

    #expect(abs(CMTimeGetSeconds(result[0].startTime) - 1) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[1].startTime) - 23) < 0.001)
}

@Test func insertInsideSubtitleStretchesIt() {
    // Вставка попала в середину фразы: разрывать её надвое значило бы показать
    // один и тот же текст дважды, поэтому подпись растягивается
    let entries = [entry("длинная фраза", 8, 14)]
    let result = SubtitleRipple.applyInsertion(to: entries, at: t(10), duration: t(5))

    #expect(abs(CMTimeGetSeconds(result[0].startTime) - 8) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[0].endTime) - 19) < 0.001)
}

@Test func insertMovesWordTimingsToo() {
    // Караоке-подсветка разъедется, если сдвинуть только границы реплики
    let entries = [entry("два слова", 5, 7, words: [("два", 5, 6), ("слова", 6, 7)])]
    let result = SubtitleRipple.applyInsertion(to: entries, at: .zero, duration: t(3))

    #expect(result[0].words.count == 2)
    #expect(abs(CMTimeGetSeconds(result[0].words[0].startTime) - 8) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[0].words[1].endTime) - 10) < 0.001)
}

@Test func zeroDurationInsertChangesNothing() {
    let entries = [entry("текст", 1, 2)]
    let result = SubtitleRipple.applyInsertion(to: entries, at: .zero, duration: .zero)
    #expect(result == entries)
}

// MARK: - Вырез

@Test func cutBeforeSubtitleMovesItBack() {
    let entries = [entry("речь", 20, 22)]
    let result = SubtitleRipple.applyRemovals(to: entries, [range(5, 4)])

    #expect(abs(CMTimeGetSeconds(result[0].startTime) - 16) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[0].endTime) - 18) < 0.001)
}

@Test func cutSwallowingSubtitleRemovesIt() {
    // Сказанного в смонтированном ролике больше нет — подписи тоже быть не должно
    let entries = [entry("вырезано", 10, 12), entry("осталось", 20, 22)]
    let result = SubtitleRipple.applyRemovals(to: entries, [range(9, 5)])

    #expect(result.count == 1)
    #expect(result[0].text == "осталось")
}

@Test func cutInsideSubtitleShortensIt() {
    let entries = [entry("фраза", 10, 16)]
    let result = SubtitleRipple.applyRemovals(to: entries, [range(12, 2)])

    #expect(result.count == 1)
    #expect(abs(CMTimeGetSeconds(result[0].startTime) - 10) < 0.001)
    #expect(abs(CMTimeGetSeconds(result[0].endTime) - 14) < 0.001)
}

@Test func cutDropsWordsThatDisappeared() {
    let entries = [entry(
        "три слова тут", 10, 13,
        words: [("три", 10, 11), ("слова", 11, 12), ("тут", 12, 13)]
    )]
    let result = SubtitleRipple.applyRemovals(to: entries, [range(11, 1)])

    #expect(result.count == 1)
    #expect(result[0].words.count == 2)
    #expect(result[0].words.map(\.word) == ["три", "тут"])
}

@Test func emptyRemovalsChangeNothing() {
    let entries = [entry("текст", 1, 2)]
    #expect(SubtitleRipple.applyRemovals(to: entries, []) == entries)
}

@Test func subtitlesAndGraphicsMoveTogetherOnInsert() {
    // Титр, поставленный под конкретную фразу, обязан остаться под ней после вставки
    let entries = [entry("про налоги", 20, 23)]
    var timeline = EditTimeline(
        sources: [],
        clips: [TimelineClip(
            sourceID: UUID(), availableRange: range(0, 100), sourceRange: range(0, 40)
        )],
        graphics: [GraphicClip(
            sourceID: UUID(), sourceRange: range(0, 3), timelineStart: t(20)
        )]
    )
    timeline.recalculateOffsets()

    let insertAt = t(5)
    let insertDuration = t(4)
    timeline.applyInsertion(at: insertAt, duration: insertDuration)
    let moved = SubtitleRipple.applyInsertion(to: entries, at: insertAt, duration: insertDuration)

    #expect(abs(CMTimeGetSeconds(moved[0].startTime)
                - CMTimeGetSeconds(timeline.graphics[0].timelineStart)) < 0.001)
}
