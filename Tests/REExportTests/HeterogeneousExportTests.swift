import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import REExport
import RECore
import RETimeline

// Разнородные исходники — главный риск однопроходного экспорта: у роликов разные
// разрешения, частоты кадров и, что важнее всего, разные форматы звука. Здесь всё это
// сходится в одном файле на выходе.

private struct Fixture {
    let size: CGSize
    let fps: Int32
    let sampleRate: Double
    let channels: UInt32
    let color: (r: UInt8, g: UInt8, b: UInt8)
}

private func writeFixture(_ fixture: Fixture, seconds: Double, to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(fixture.size.width),
        AVVideoHeightKey: Int(fixture.size.height)
    ])
    videoInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(fixture.size.width),
            kCVPixelBufferHeightKey as String: Int(fixture.size.height)
        ]
    )
    writer.add(videoInput)

    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: fixture.sampleRate,
        AVNumberOfChannelsKey: Int(fixture.channels),
        AVEncoderBitRateKey: 64000
    ])
    audioInput.expectsMediaDataInRealTime = false
    writer.add(audioInput)

    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    // Дорожки пишутся параллельно: AVAssetWriter чередует их сам и перестаёт принимать
    // видео, пока не увидит звук той же поры. Последовательная запись «сначала всё видео,
    // потом весь звук» уходит в вечное ожидание isReadyForMoreMediaData.
    async let videoDone: Void = writeVideo(fixture, seconds: seconds, input: videoInput, adaptor: adaptor)
    async let audioDone: Void = writeAudio(fixture, seconds: seconds, input: audioInput)
    _ = try await (videoDone, audioDone)

    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

private func writeVideo(
    _ fixture: Fixture, seconds: Double,
    input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
) async throws {
    let frameCount = Int(seconds * Double(fixture.fps))
    for frame in 0..<frameCount {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else { throw CocoaError(.fileWriteUnknown) }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
                let row = pointer + y * bytesPerRow
                for x in 0..<CVPixelBufferGetWidth(pixelBuffer) {
                    let pixel = row + x * 4
                    pixel[0] = fixture.color.b
                    pixel[1] = fixture.color.g
                    pixel[2] = fixture.color.r
                    pixel[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fixture.fps))
    }
    input.markAsFinished()
}

private func writeAudio(_ fixture: Fixture, seconds: Double, input audioInput: AVAssetWriterInput) async throws {
    // --- звук: синус 440 Гц, чтобы дорожка была не пустой ---
    var asbd = AudioStreamBasicDescription(
        mSampleRate: fixture.sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * fixture.channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4 * fixture.channels,
        mChannelsPerFrame: fixture.channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format
    )
    guard let format else { throw CocoaError(.fileWriteUnknown) }

    let framesPerChunk = Int(fixture.sampleRate / 10)
    let chunks = Int(seconds * 10)
    var phase = 0.0
    let phaseStep = 2 * Double.pi * 440 / fixture.sampleRate

    for chunk in 0..<chunks {
        while !audioInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }

        var samples = [Float](repeating: 0, count: framesPerChunk * Int(fixture.channels))
        for frame in 0..<framesPerChunk {
            let value = Float(sin(phase) * 0.25)
            phase += phaseStep
            for channel in 0..<Int(fixture.channels) {
                samples[frame * Int(fixture.channels) + channel] = value
            }
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { throw CocoaError(.fileWriteUnknown) }
        _ = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fixture.sampleRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(chunk * framesPerChunk),
                timescale: CMTimeScale(fixture.sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: framesPerChunk,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: [MemoryLayout<Float>.size * Int(fixture.channels)],
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { throw CocoaError(.fileWriteUnknown) }
        audioInput.append(sampleBuffer)
    }
    audioInput.markAsFinished()
}

private func makeSource(url: URL) async throws -> MediaSource {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    return MediaSource(
        url: url,
        duration: try await asset.load(.duration),
        naturalSize: try await track.load(.naturalSize),
        preferredTransform: try await track.load(.preferredTransform),
        nominalFrameRate: Double(try await track.load(.nominalFrameRate)),
        hasAudio: try await !asset.loadTracks(withMediaType: .audio).isEmpty
    )
}

@Test func exportJoinsSourcesWithDifferentAudioFormats() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Разные разрешения, разные fps и — главное — разные форматы звука
    let firstURL = dir.appendingPathComponent("first.mp4")
    let secondURL = dir.appendingPathComponent("second.mp4")
    try await writeFixture(
        Fixture(size: CGSize(width: 320, height: 240), fps: 30,
                sampleRate: 44100, channels: 1, color: (220, 20, 20)),
        seconds: 2, to: firstURL
    )
    try await writeFixture(
        Fixture(size: CGSize(width: 240, height: 320), fps: 25,
                sampleRate: 48000, channels: 2, color: (20, 20, 220)),
        seconds: 2, to: secondURL
    )

    let first = try await makeSource(url: firstURL)
    let second = try await makeSource(url: secondURL)
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600))

    let timeline = EditTimeline(
        sources: [first, second],
        clips: [
            TimelineClip(sourceID: first.id, availableRange: range, sourceRange: range),
            TimelineClip(sourceID: second.id, availableRange: range, sourceRange: range),
        ],
        overlays: [OverlayClip(
            sourceID: second.id,
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)),
            timelineStart: CMTime(seconds: 0.5, preferredTimescale: 600)
        )]
    )

    let outputURL = dir.appendingPathComponent("out.mp4")
    var options = RenderOptions.default
    options.outputAspect = .vertical
    try await ExportService.export(
        timeline: timeline, to: outputURL, preset: .medium, renderOptions: options
    ) { _ in }

    let result = AVURLAsset(url: outputURL)
    let duration = CMTimeGetSeconds(try await result.load(.duration))
    #expect(abs(duration - 3.0) < 0.2)

    let videoTracks = try await result.loadTracks(withMediaType: .video)
    let audioTracks = try await result.loadTracks(withMediaType: .audio)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.count == 1)

    // Кадр — выбранный холст 9:16, а не размер первого исходника
    let size = try await #require(videoTracks.first).load(.naturalSize)
    #expect(size == CGSize(width: 1080, height: 1920))

    // Звук приведён к формату проекта независимо от того, что было в исходниках
    let format = try await #require(try await audioTracks.first?.load(.formatDescriptions).first)
    let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    #expect(asbd.mSampleRate == 48000)
    #expect(asbd.mChannelsPerFrame == 2)

    // Звук не пустой: дорожка занимает почти всю длину результата
    let audioDuration = CMTimeGetSeconds(try await #require(audioTracks.first).load(.timeRange).duration)
    #expect(audioDuration > 2.5)
}

@Test func exportKeepsSyncWhenOneSourceIsSilent() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Немой b-roll в середине: раньше пропуск вставки звука увёл бы всё, что после него
    let loudURL = dir.appendingPathComponent("loud.mp4")
    let silentURL = dir.appendingPathComponent("silent.mp4")
    try await writeFixture(
        Fixture(size: CGSize(width: 320, height: 240), fps: 30,
                sampleRate: 48000, channels: 2, color: (220, 20, 20)),
        seconds: 2, to: loudURL
    )
    try await writeSilentVideo(size: CGSize(width: 320, height: 240), seconds: 2, to: silentURL)

    let loud = try await makeSource(url: loudURL)
    let silent = try await makeSource(url: silentURL)
    #expect(silent.hasAudio == false)

    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.0, preferredTimescale: 600))
    let timeline = EditTimeline(
        sources: [loud, silent],
        clips: [
            TimelineClip(sourceID: loud.id, availableRange: range, sourceRange: range),
            TimelineClip(sourceID: silent.id, availableRange: range, sourceRange: range),
            TimelineClip(sourceID: loud.id, availableRange: range, sourceRange: range),
        ]
    )

    let outputURL = dir.appendingPathComponent("out.mp4")
    try await ExportService.export(timeline: timeline, to: outputURL, preset: .medium) { _ in }

    let result = AVURLAsset(url: outputURL)
    #expect(abs(CMTimeGetSeconds(try await result.load(.duration)) - 3.0) < 0.2)

    // Звуковая дорожка тянется на все три секунды: немой кусок занял своё место пустотой,
    // а не схлопнулся, утащив третий клип на секунду вперёд
    let audioTracks = try await result.loadTracks(withMediaType: .audio)
    let audioDuration = CMTimeGetSeconds(try await #require(audioTracks.first).load(.timeRange).duration)
    #expect(audioDuration > 2.5)
}

/// Ролик вообще без аудиодорожки
private func writeSilentVideo(size: CGSize, seconds: Double, to url: URL) async throws {
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

    for frame in 0..<Int(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else { throw CocoaError(.fileWriteUnknown) }
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}
