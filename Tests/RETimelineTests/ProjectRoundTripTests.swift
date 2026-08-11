import Testing
import Foundation
import AVFoundation
import CoreMedia
import RECore
@testable import RETimeline

// Жизненный цикл проекта целиком: собрали монтаж → записали файл → прочитали обратно →
// собрали композицию. Тесты `ProjectStore` работают на выдуманных путях и потому не видят
// главного риска документа — что закладки на исходники не переживут запись и чтение,
// а кадрирование и перебивки потеряются по дороге.

private func fixtureVideo(seconds: Double, size: CGSize, to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height)
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
    )
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frames = Int(seconds * 30)
    var pool: CVPixelBuffer?
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        CVPixelBufferCreate(
            nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pool
        )
        guard let buffer = pool else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

private func source(for url: URL, seconds: Double, size: CGSize) async throws -> MediaSource {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first
    var media = MediaSource(
        url: url,
        duration: CMTime(seconds: seconds, preferredTimescale: 600),
        naturalSize: try await track?.load(.naturalSize) ?? size,
        preferredTransform: try await track?.load(.preferredTransform) ?? .identity,
        nominalFrameRate: 30,
        hasAudio: false
    )
    try? media.createBookmark()
    return media
}

@Test func savedProjectReopensAndStillBuilds() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Два разнородных исходника: вертикальный хребет и горизонтальная перебивка
    let spineURL = dir.appendingPathComponent("spine.mp4")
    let brollURL = dir.appendingPathComponent("broll.mp4")
    try await fixtureVideo(seconds: 3, size: CGSize(width: 360, height: 640), to: spineURL)
    try await fixtureVideo(seconds: 2, size: CGSize(width: 640, height: 360), to: brollURL)

    let spine = try await source(for: spineURL, seconds: 3, size: CGSize(width: 360, height: 640))
    let broll = try await source(for: brollURL, seconds: 2, size: CGSize(width: 640, height: 360))

    let spineRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
    var clip = TimelineClip(sourceID: spine.id, availableRange: spineRange, sourceRange: spineRange)
    clip.framing = ClipFraming(scale: 1.4, offset: CGPoint(x: 0.1, y: -0.05))

    let overlay = OverlayClip(
        sourceID: broll.id,
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
        timelineStart: CMTime(seconds: 1, preferredTimescale: 600),
        framing: ClipFraming(scale: 0.8, offset: .zero)
    )

    let original = EditTimeline(sources: [spine, broll], clips: [clip], overlays: [overlay])
    let snapshot = ProjectSnapshot(
        name: "Круговой рейс",
        timeline: original,
        subtitleEntries: [],
        subtitleStyle: .classic,
        renderOptions: .default
    )

    let projectURL = dir.appendingPathComponent("проект.silencecut")
    try ProjectStore.save(snapshot, to: projectURL)

    // --- Читаем как будто в новом запуске приложения ---
    let loaded = try ProjectStore.load(from: projectURL)

    #expect(loaded.version == ProjectSnapshot.currentVersion)
    #expect(loaded.name == "Круговой рейс")
    #expect(loaded.timeline.sources.count == 2)
    #expect(loaded.timeline.clips.count == 1)
    #expect(loaded.timeline.overlays.count == 1)

    // Кадрирование переживает запись — иначе после открытия кадр «прыгнет»
    let loadedFraming = try #require(loaded.timeline.clips.first?.framing)
    #expect(abs(loadedFraming.scale - 1.4) < 0.0001)
    #expect(abs(loadedFraming.offset.x - 0.1) < 0.0001)
    #expect(abs(loadedFraming.offset.y - (-0.05)) < 0.0001)
    #expect(abs((loaded.timeline.overlays.first?.framing.scale ?? 0) - 0.8) < 0.0001)

    // Перебивка стоит там же и той же длины
    let loadedOverlay = try #require(loaded.timeline.overlays.first)
    #expect(abs(CMTimeGetSeconds(loadedOverlay.timelineStart) - 1) < 0.001)
    #expect(abs(CMTimeGetSeconds(loadedOverlay.sourceRange.duration) - 1) < 0.001)

    // Клипы по-прежнему указывают на существующие источники реестра
    let ids = Set(loaded.timeline.sources.map(\.id))
    #expect(ids.contains(try #require(loaded.timeline.clips.first?.sourceID)))
    #expect(ids.contains(loadedOverlay.sourceID))

    // Закладки резолвятся в те же файлы: без этого проект открылся бы «офлайн»
    var restored = loaded.timeline
    for index in restored.sources.indices {
        let resolved = restored.sources[index].resolveBookmark()
        #expect(resolved != nil)
    }

    // И главное — из прочитанного проекта собирается композиция
    let result = try await CompositionBuilder.build(from: restored)
    #expect(abs(CMTimeGetSeconds(result.composition.duration) - 3) < 0.2)
    let videoTracks = result.composition.tracks(withMediaType: .video)
    #expect(videoTracks.count == 2)   // хребет и перебивка
}

@Test func projectSurvivesMoveToAnotherFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let elsewhere = dir.appendingPathComponent("другая папка")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let videoURL = dir.appendingPathComponent("ролик.mp4")
    try await fixtureVideo(seconds: 1, size: CGSize(width: 320, height: 240), to: videoURL)
    let media = try await source(for: videoURL, seconds: 1, size: CGSize(width: 320, height: 240))

    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
    let timeline = EditTimeline(
        sources: [media],
        clips: [TimelineClip(sourceID: media.id, availableRange: range, sourceRange: range)]
    )
    let snapshot = ProjectSnapshot(
        name: "Переезд", timeline: timeline,
        subtitleEntries: [], subtitleStyle: .classic
    )

    // Проект лежит в одной папке, видео в другой — именно ради этого файл проекта
    // и перестал быть sidecar'ом рядом с роликом
    let projectURL = elsewhere.appendingPathComponent("переезд.silencecut")
    try ProjectStore.save(snapshot, to: projectURL)

    let loaded = try ProjectStore.load(from: projectURL).timeline
    var restoredSource = try #require(loaded.sources.first)
    #expect(restoredSource.resolveBookmark() != nil)

    let result = try await CompositionBuilder.build(from: loaded)
    #expect(CMTimeGetSeconds(result.composition.duration) > 0.5)
}
