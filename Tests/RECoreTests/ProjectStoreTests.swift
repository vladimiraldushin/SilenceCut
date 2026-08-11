import Testing
import Foundation
import CoreMedia
import CoreGraphics
@testable import RECore

private let storeTestSourceID = UUID()

@Test func projectSnapshotRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let projectURL = dir.appendingPathComponent("video.silencecut")

    var timeline = EditTimeline(clips: [
        TimelineClip(
            sourceID: storeTestSourceID,
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        ),
        TimelineClip(
            sourceID: storeTestSourceID,
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: CMTime(seconds: 4, preferredTimescale: 600), duration: CMTime(seconds: 3, preferredTimescale: 600))
        ),
    ])
    timeline.recalculateOffsets()

    let entry1 = SubtitleEntry(
        text: "Привет мир",
        startTime: .zero,
        endTime: CMTime(seconds: 1, preferredTimescale: 600),
        words: [
            WordTiming(word: "Привет", startTime: .zero, endTime: CMTime(seconds: 0.5, preferredTimescale: 600)),
            WordTiming(word: "мир", startTime: CMTime(seconds: 0.5, preferredTimescale: 600), endTime: CMTime(seconds: 1, preferredTimescale: 600)),
        ]
    )
    let entry2 = SubtitleEntry(
        text: "Как дела сегодня",
        startTime: CMTime(seconds: 4, preferredTimescale: 600),
        endTime: CMTime(seconds: 5.5, preferredTimescale: 600),
        words: [
            WordTiming(word: "Как", startTime: CMTime(seconds: 4, preferredTimescale: 600), endTime: CMTime(seconds: 4.3, preferredTimescale: 600)),
            WordTiming(word: "дела", startTime: CMTime(seconds: 4.3, preferredTimescale: 600), endTime: CMTime(seconds: 4.8, preferredTimescale: 600)),
            WordTiming(word: "сегодня", startTime: CMTime(seconds: 4.8, preferredTimescale: 600), endTime: CMTime(seconds: 5.5, preferredTimescale: 600)),
        ]
    )

    let snapshot = ProjectSnapshot(
        name: "Тестовый проект",
        timeline: timeline,
        subtitleEntries: [entry1, entry2],
        subtitleStyle: .capcut
    )

    try ProjectStore.save(snapshot, to: projectURL)
    let loaded = try #require(try ProjectStore.load(from: projectURL))

    #expect(loaded.name == snapshot.name)
    #expect(loaded.timeline.clips.count == 2)
    #expect(CMTimeGetSeconds(loaded.timeline.duration) == CMTimeGetSeconds(timeline.duration))
    #expect(loaded.subtitleEntries.count == 2)
    #expect(loaded.subtitleEntries[0].text == entry1.text)
    #expect(loaded.subtitleEntries[1].text == entry2.text)
    #expect(loaded.subtitleEntries[0].words.count == 2)
    #expect(loaded.subtitleEntries[1].words.count == 3)
    #expect(loaded.subtitleStyle == SubtitleStyle.capcut)
}

@Test func loadingMissingFileThrows() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let projectURL = dir.appendingPathComponent("missing.silencecut")
    #expect(throws: (any Error).self) { try ProjectStore.load(from: projectURL) }
}

@Test func loadingCorruptedFileThrows() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let projectURL = dir.appendingPathComponent("broken.silencecut")
    try Data("это не json".utf8).write(to: projectURL)

    #expect(throws: (any Error).self) { try ProjectStore.load(from: projectURL) }
}

@Test func subtitleStylePresetStoreRoundTrip() throws {
    let suiteName = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    SubtitleStylePresetStore.defaults = defaults
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        SubtitleStylePresetStore.defaults = .standard
    }

    #expect(SubtitleStylePresetStore.names().isEmpty)

    SubtitleStylePresetStore.save(.hormozi, named: "Мой стиль")
    SubtitleStylePresetStore.save(.script, named: "Второй")

    #expect(SubtitleStylePresetStore.names() == ["Второй", "Мой стиль"])
    #expect(SubtitleStylePresetStore.load(named: "Мой стиль") == SubtitleStyle.hormozi)
    #expect(SubtitleStylePresetStore.load(named: "Второй") == SubtitleStyle.script)
    #expect(SubtitleStylePresetStore.load(named: "Отсутствует") == nil)

    SubtitleStylePresetStore.delete(named: "Мой стиль")
    #expect(SubtitleStylePresetStore.names() == ["Второй"])
    #expect(SubtitleStylePresetStore.load(named: "Мой стиль") == nil)
}
