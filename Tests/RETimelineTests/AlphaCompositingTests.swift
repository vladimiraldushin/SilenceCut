import Testing
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import RECore
@testable import RETimeline

// Титр обязан лежать ПОВЕРХ картинки, а не вместо неё. Значит встроенный компоновщик
// AVFoundation должен уважать альфу верхнего слоя. Документация об этом молчит, поэтому
// здесь это проверяется фактом на ProRes 4444 — единственном кодеке с альфой, который
// AVFoundation читает нативно.

private struct BGRA { let b, g, r, a: UInt8 }

/// Кадр с прозрачным фоном и непрозрачным квадратом в середине
private func writeAlphaFixture(
    size: CGSize, seconds: Double, square: BGRA, to url: URL
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes4444,
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

    let width = Int(size.width)
    let height = Int(size.height)
    let squareRect = (
        x: width / 4, y: height / 4,
        w: width / 2, h: height / 2
    )

    for frame in 0..<Int(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { continue }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            // Весь кадр прозрачный: премультиплицированная альфа, поэтому нули везде
            memset(base, 0, rowBytes * height)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in squareRect.y..<(squareRect.y + squareRect.h) {
                for x in squareRect.x..<(squareRect.x + squareRect.w) {
                    let offset = y * rowBytes + x * 4
                    pixels[offset + 0] = square.b
                    pixels[offset + 1] = square.g
                    pixels[offset + 2] = square.r
                    pixels[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }

    input.markAsFinished()
    await writer.finishWriting()
}

/// Полностью залитый непрозрачный кадр — то, что лежит под титром
private func writeSolidFixture(
    size: CGSize, seconds: Double, color: BGRA, to url: URL
) async throws {
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
    )
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let width = Int(size.width)
    let height = Int(size.height)
    for frame in 0..<Int(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    pixels[offset + 0] = color.b
                    pixels[offset + 1] = color.g
                    pixels[offset + 2] = color.r
                    pixels[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// Цвет пикселя в доле кадра (0…1 от левого верхнего угла)
private func pixel(
    _ composition: AVComposition,
    videoComposition: AVVideoComposition,
    at seconds: Double,
    fraction: CGPoint
) throws -> BGRA {
    let generator = AVAssetImageGenerator(asset: composition)
    generator.videoComposition = videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(
        at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil
    )

    let x = Int(CGFloat(image.width) * fraction.x)
    let y = Int(CGFloat(image.height) * fraction.y)

    var data = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )
    context?.draw(image, in: CGRect(x: -x, y: -(image.height - y - 1), width: image.width, height: image.height))
    // premultipliedFirst в порядке ARGB
    return BGRA(b: data[3], g: data[2], r: data[1], a: data[0])
}

@Test func builtInCompositorHonoursProRes4444Alpha() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let size = CGSize(width: 320, height: 240)
    let baseURL = dir.appendingPathComponent("base.mp4")
    let titleURL = dir.appendingPathComponent("title.mov")

    // Снизу синий фон, сверху красный квадрат на прозрачном
    try await writeSolidFixture(
        size: size, seconds: 1, color: BGRA(b: 220, g: 40, r: 20, a: 255), to: baseURL
    )
    try await writeAlphaFixture(
        size: size, seconds: 1, square: BGRA(b: 20, g: 40, r: 220, a: 255), to: titleURL
    )

    let composition = AVMutableComposition()
    let baseTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
    )!
    let titleTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
    )!

    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
    let baseAsset = AVURLAsset(url: baseURL)
    let titleAsset = AVURLAsset(url: titleURL)
    try baseTrack.insertTimeRange(
        range, of: try await baseAsset.loadTracks(withMediaType: .video)[0], at: .zero
    )
    try titleTrack.insertTimeRange(
        range, of: try await titleAsset.loadTracks(withMediaType: .video)[0], at: .zero
    )

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
    // Первый в массиве — верхний слой; этот порядок уже зафиксирован OverlayCompositionTests
    instruction.layerInstructions = [
        AVMutableVideoCompositionLayerInstruction(assetTrack: titleTrack),
        AVMutableVideoCompositionLayerInstruction(assetTrack: baseTrack),
    ]

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = size
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    videoComposition.instructions = [instruction]

    let center = try pixel(
        composition, videoComposition: videoComposition,
        at: 0.5, fraction: CGPoint(x: 0.5, y: 0.5)
    )
    let corner = try pixel(
        composition, videoComposition: videoComposition,
        at: 0.5, fraction: CGPoint(x: 0.05, y: 0.05)
    )

    // В середине — квадрат титра
    #expect(center.r > center.b + 40)

    // В углу титр прозрачен, и должен просвечивать нижний слой.
    // Если здесь чёрное — альфа игнорируется и понадобится свой AVVideoCompositing.
    #expect(corner.b > corner.r + 40)
}

private func makeSource(url: URL, seconds: Double) async throws -> MediaSource {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first
    return MediaSource(
        url: url,
        duration: CMTime(seconds: seconds, preferredTimescale: 600),
        naturalSize: try await track?.load(.naturalSize) ?? .zero,
        preferredTransform: try await track?.load(.preferredTransform) ?? .identity,
        nominalFrameRate: 30,
        hasAudio: false
    )
}

@Test func graphicStaysVisibleOverCutaway() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let size = CGSize(width: 320, height: 240)
    let spineURL = dir.appendingPathComponent("spine.mp4")
    let cutawayURL = dir.appendingPathComponent("cutaway.mp4")
    let titleURL = dir.appendingPathComponent("title.mov")

    // Хребет красный, перебивка синяя, титр — зелёный квадрат на прозрачном
    try await writeSolidFixture(size: size, seconds: 2, color: BGRA(b: 20, g: 40, r: 220, a: 255), to: spineURL)
    try await writeSolidFixture(size: size, seconds: 2, color: BGRA(b: 220, g: 40, r: 20, a: 255), to: cutawayURL)
    try await writeAlphaFixture(size: size, seconds: 2, square: BGRA(b: 20, g: 220, r: 20, a: 255), to: titleURL)

    let spine = try await makeSource(url: spineURL, seconds: 2)
    let cutaway = try await makeSource(url: cutawayURL, seconds: 2)
    let title = try await makeSource(url: titleURL, seconds: 2)

    let full = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
    let half = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))

    let timeline = EditTimeline(
        sources: [spine, cutaway, title],
        clips: [TimelineClip(sourceID: spine.id, availableRange: full, sourceRange: full)],
        // Перебивка и титр накрывают один и тот же кусок 0.5…1.5
        overlays: [OverlayClip(
            sourceID: cutaway.id, sourceRange: half,
            timelineStart: CMTime(seconds: 0.5, preferredTimescale: 600)
        )],
        graphics: [GraphicClip(
            sourceID: title.id, sourceRange: half,
            timelineStart: CMTime(seconds: 0.5, preferredTimescale: 600)
        )]
    )

    let result = try await CompositionBuilder.build(from: timeline)
    let videoComposition = try #require(result.videoComposition)

    let center = try pixel(
        result.composition, videoComposition: videoComposition,
        at: 1.0, fraction: CGPoint(x: 0.5, y: 0.5)
    )
    let corner = try pixel(
        result.composition, videoComposition: videoComposition,
        at: 1.0, fraction: CGPoint(x: 0.05, y: 0.05)
    )

    // В середине — титр: он выше перебивки, иначе надпись пропадала бы под b-roll
    #expect(center.g > center.r + 40)
    #expect(center.g > center.b + 40)

    // По краям титр прозрачен и видна перебивка (синяя), а не хребет (красный)
    #expect(corner.b > corner.r + 40)
}

@Test func overlappingGraphicsAllSurvive() async throws {
    // Бегущая строка идёт через весь ролик, подписи говорящих появляются поверх неё.
    // Пока дорожка графики была одна, второй титр молча пропадал при сборке.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let size = CGSize(width: 320, height: 240)
    let spineURL = dir.appendingPathComponent("spine.mp4")
    let longURL = dir.appendingPathComponent("long.mov")
    let shortURL = dir.appendingPathComponent("short.mov")

    try await writeSolidFixture(size: size, seconds: 3, color: BGRA(b: 20, g: 40, r: 220, a: 255), to: spineURL)
    // Длинная «лента» — зелёный квадрат, короткая «подпись» — синий
    try await writeAlphaFixture(size: size, seconds: 3, square: BGRA(b: 20, g: 220, r: 20, a: 255), to: longURL)
    try await writeAlphaFixture(size: size, seconds: 1, square: BGRA(b: 220, g: 40, r: 20, a: 255), to: shortURL)

    let spine = try await makeSource(url: spineURL, seconds: 3)
    let long = try await makeSource(url: longURL, seconds: 3)
    let short = try await makeSource(url: shortURL, seconds: 1)

    let full = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
    let one = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))

    let timeline = EditTimeline(
        sources: [spine, long, short],
        clips: [TimelineClip(sourceID: spine.id, availableRange: full, sourceRange: full)],
        graphics: [
            GraphicClip(sourceID: long.id, sourceRange: full, timelineStart: .zero),
            GraphicClip(sourceID: short.id, sourceRange: one,
                        timelineStart: CMTime(seconds: 1, preferredTimescale: 600)),
        ]
    )

    let result = try await CompositionBuilder.build(from: timeline)
    // Две дорожки графики плюс дорожка хребта
    #expect(result.composition.tracks(withMediaType: .video).count == 3)

    let videoComposition = try #require(result.videoComposition)
    // В момент наложения сверху должна быть подпись, заведённая позже
    let center = try pixel(result.composition, videoComposition: videoComposition,
                           at: 1.5, fraction: CGPoint(x: 0.5, y: 0.5))
    #expect(center.r > center.g + 40, "верхний титр не виден: наложение снова теряется")
}
