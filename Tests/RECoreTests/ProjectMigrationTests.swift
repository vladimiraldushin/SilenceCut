import Testing
import Foundation
import CoreMedia
import CoreGraphics
@testable import RECore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Sidecar первой версии: у клипов sourceURL, полей sources и version нет
private func legacySidecarJSON(clips: String) throws -> String {
    let style = String(data: try JSONEncoder().encode(SubtitleStyle.classic), encoding: .utf8)!
    return """
    {
      "name": "test",
      "savedAt": "2026-01-01T00:00:00Z",
      "subtitleEntries": [],
      "subtitleStyle": \(style),
      "timeline": { "clips": [\(clips)] }
    }
    """
}

private func legacyClip(id: String, url: String, start: Double, duration: Double) -> String {
    """
    {
      "id": "\(id)",
      "sourceURL": "\(url)",
      "availableRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 60000, "timescale": 600}},
      "sourceRange": {"start": {"value": \(Int(start * 600)), "timescale": 600}, "duration": {"value": \(Int(duration * 600)), "timescale": 600}},
      "timelineOffset": {"value": 0, "timescale": 600},
      "speed": 1,
      "isEnabled": true
    }
    """
}

@Test func legacyProjectFileGetsSynthesizedSource() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let projectURL = dir.appendingPathComponent("take1.silencecut")

    let json = try legacySidecarJSON(clips: legacyClip(
        id: "11111111-1111-1111-1111-111111111111",
        url: "file:///videos/take1.mp4", start: 0, duration: 10
    ))
    try Data(json.utf8).write(to: projectURL)

    let snapshot = try #require(try ProjectStore.load(from: projectURL))
    #expect(snapshot.version == 1)
    #expect(snapshot.timeline.sources.count == 1)

    let source = try #require(snapshot.timeline.sources.first)
    #expect(source.url.lastPathComponent == "take1.mp4")
    #expect(snapshot.timeline.clips.first?.sourceID == source.id)
    #expect(snapshot.timeline.clips.first?.legacySourceURL == nil)
    #expect(snapshot.timeline.clips.first?.framing == .default)
}

@Test func legacyProjectWithRepeatedSourceMakesOneRegistryEntry() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let projectURL = dir.appendingPathComponent("take1.silencecut")

    // Три клипа одного файла — после вырезания пауз так выглядит любой старый проект
    let clips = [
        legacyClip(id: "11111111-1111-1111-1111-111111111111", url: "file:///videos/take1.mp4", start: 0, duration: 4),
        legacyClip(id: "22222222-2222-2222-2222-222222222222", url: "file:///videos/take1.mp4", start: 6, duration: 3),
        legacyClip(id: "33333333-3333-3333-3333-333333333333", url: "file:///videos/take1.mp4", start: 12, duration: 5),
    ].joined(separator: ",")
    try Data(try legacySidecarJSON(clips: clips).utf8).write(to: projectURL)

    let snapshot = try #require(try ProjectStore.load(from: projectURL))
    #expect(snapshot.timeline.sources.count == 1)
    let sourceID = try #require(snapshot.timeline.sources.first?.id)
    #expect(snapshot.timeline.clips.allSatisfy { $0.sourceID == sourceID })
}

@Test func migratedSourceDurationCoversWholeVideo() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let projectURL = dir.appendingPathComponent("take1.silencecut")

    try Data(try legacySidecarJSON(clips: legacyClip(
        id: "11111111-1111-1111-1111-111111111111",
        url: "file:///videos/take1.mp4", start: 0, duration: 10
    )).utf8).write(to: projectURL)

    let snapshot = try #require(try ProjectStore.load(from: projectURL))
    // Длительность берётся из availableRange клипа — это полная длина исходника
    #expect(abs(CMTimeGetSeconds(try #require(snapshot.timeline.sources.first).duration) - 100) < 0.001)
}

@Test func currentSnapshotRoundTripsWithSourcesAndOverlays() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let projectURL = dir.appendingPathComponent("a.silencecut")

    let source = MediaSource(
        url: URL(fileURLWithPath: "/videos/a.mp4"),
        duration: CMTime(seconds: 10, preferredTimescale: 600),
        naturalSize: CGSize(width: 1080, height: 1920),
        preferredTransform: .identity,
        nominalFrameRate: 30,
        hasAudio: true,
        integratedLUFS: -21,
        gain: 1.2
    )
    let timeline = EditTimeline(
        sources: [source],
        clips: [TimelineClip(
            sourceID: source.id,
            availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
        )],
        overlays: [OverlayClip(
            sourceID: source.id,
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            timelineStart: CMTime(seconds: 3, preferredTimescale: 600)
        )]
    )
    let snapshot = ProjectSnapshot(
        name: "x", timeline: timeline, subtitleEntries: [], subtitleStyle: .classic
    )
    try ProjectStore.save(snapshot, to: projectURL)

    let loaded = try #require(try ProjectStore.load(from: projectURL))
    #expect(loaded.version == 2)
    #expect(loaded.timeline.sources.first?.id == source.id)
    #expect(loaded.timeline.sources.first?.integratedLUFS == -21)
    #expect(loaded.timeline.overlays.count == 1)
}

@Test func saveToArbitraryPathWritesExactly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("Мой проект.silencecut")

    let snapshot = ProjectSnapshot(
        name: "x", timeline: EditTimeline(), subtitleEntries: [], subtitleStyle: .classic
    )
    try ProjectStore.save(snapshot, to: target)

    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(try ProjectStore.load(from: target).name == "x")
}
