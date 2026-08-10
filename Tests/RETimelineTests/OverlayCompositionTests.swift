import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import RETimeline
import RECore

// Порядок слоёв в layerInstructions документирован невнятно, а от него зависит,
// увидит ли пользователь перебивку или хребет под ней. Поэтому здесь не рассуждения,
// а факт: собираем композицию из двух одноцветных роликов и смотрим на пиксель.

private let fixtureSize = CGSize(width: 160, height: 120)

private struct RGB {
    let r: UInt8, g: UInt8, b: UInt8
}

private let red = RGB(r: 220, g: 20, b: 20)
private let blue = RGB(r: 20, g: 20, b: 220)

/// Пишет короткий ролик, целиком залитый одним цветом
private func writeSolidVideo(color: RGB, seconds: Double, to url: URL) async throws {
    let fps: Int32 = 10
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(fixtureSize.width),
        AVVideoHeightKey: Int(fixtureSize.height)
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(fixtureSize.width),
            kCVPixelBufferHeightKey as String: Int(fixtureSize.height)
        ]
    )
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frameCount = Int(seconds * Double(fps))
    for frame in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else { throw CocoaError(.fileWriteUnknown) }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = pointer + y * bytesPerRow
                for x in 0..<width {
                    let pixel = row + x * 4
                    pixel[0] = color.b
                    pixel[1] = color.g
                    pixel[2] = color.r
                    pixel[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }

    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

private func makeSource(url: URL, seconds: Double) async throws -> MediaSource {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    return MediaSource(
        url: url,
        duration: try await asset.load(.duration),
        naturalSize: try await track.load(.naturalSize),
        preferredTransform: try await track.load(.preferredTransform),
        nominalFrameRate: Double(try await track.load(.nominalFrameRate)),
        hasAudio: false
    )
}

/// Средний цвет кадра композиции в заданный момент
private func sampleColor(_ result: CompositionBuilder.Result, at seconds: Double) throws -> RGB {
    let generator = AVAssetImageGenerator(asset: result.composition)
    generator.videoComposition = result.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)

    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var totals = (r: 0, g: 0, b: 0)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        totals.r += Int(pixels[index])
        totals.g += Int(pixels[index + 1])
        totals.b += Int(pixels[index + 2])
    }
    let count = width * height
    return RGB(r: UInt8(totals.r / count), g: UInt8(totals.g / count), b: UInt8(totals.b / count))
}

@Test func overlayCoversSpineAndDisappearsAfterwards() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let spineURL = dir.appendingPathComponent("spine.mp4")
    let overlayURL = dir.appendingPathComponent("overlay.mp4")
    try await writeSolidVideo(color: red, seconds: 3, to: spineURL)
    try await writeSolidVideo(color: blue, seconds: 1, to: overlayURL)

    let spineSource = try await makeSource(url: spineURL, seconds: 3)
    let overlaySource = try await makeSource(url: overlayURL, seconds: 1)

    let spineRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 2.5, preferredTimescale: 600))
    let timeline = EditTimeline(
        sources: [spineSource, overlaySource],
        clips: [TimelineClip(sourceID: spineSource.id, availableRange: spineRange, sourceRange: spineRange)],
        overlays: [OverlayClip(
            sourceID: overlaySource.id,
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.8, preferredTimescale: 600)),
            timelineStart: CMTime(seconds: 1.0, preferredTimescale: 600)
        )]
    )

    let result = try await CompositionBuilder.build(from: timeline)

    // До перебивки виден хребет
    let before = try sampleColor(result, at: 0.4)
    #expect(before.r > before.b + 40)

    // Внутри перебивки она перекрывает хребет — иначе порядок слоёв надо менять
    let during = try sampleColor(result, at: 1.4)
    #expect(during.b > during.r + 40)

    // После перебивки снова хребет
    let after = try sampleColor(result, at: 2.2)
    #expect(after.r > after.b + 40)
}

@Test func spineJoinsTwoSourcesBackToBack() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let firstURL = dir.appendingPathComponent("first.mp4")
    let secondURL = dir.appendingPathComponent("second.mp4")
    try await writeSolidVideo(color: red, seconds: 2, to: firstURL)
    try await writeSolidVideo(color: blue, seconds: 2, to: secondURL)

    let first = try await makeSource(url: firstURL, seconds: 2)
    let second = try await makeSource(url: secondURL, seconds: 2)
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600))

    let timeline = EditTimeline(
        sources: [first, second],
        clips: [
            TimelineClip(sourceID: first.id, availableRange: range, sourceRange: range),
            TimelineClip(sourceID: second.id, availableRange: range, sourceRange: range),
        ]
    )
    let result = try await CompositionBuilder.build(from: timeline)

    #expect(abs(CMTimeGetSeconds(result.composition.duration) - 3.0) < 0.1)

    let inFirst = try sampleColor(result, at: 0.7)
    #expect(inFirst.r > inFirst.b + 40)

    let inSecond = try sampleColor(result, at: 2.2)
    #expect(inSecond.b > inSecond.r + 40)
}

@Test func silentSourceKeepsLaterClipsInSync() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("silent.mp4")
    try await writeSolidVideo(color: red, seconds: 2, to: url)
    let source = try await makeSource(url: url, seconds: 2)
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600))

    let timeline = EditTimeline(
        sources: [source],
        clips: [
            TimelineClip(sourceID: source.id, availableRange: range, sourceRange: range),
            TimelineClip(sourceID: source.id, availableRange: range, sourceRange: range),
        ]
    )
    let result = try await CompositionBuilder.build(from: timeline)

    // Немой исходник: аудиодорожки в композиции быть не должно, иначе AVAssetReader падает
    #expect(result.composition.tracks(withMediaType: .audio).isEmpty)
    #expect(abs(CMTimeGetSeconds(result.composition.duration) - 3.0) < 0.1)
}
