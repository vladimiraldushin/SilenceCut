import Testing
import Foundation
import AVFoundation
import CoreMedia
import RECore
@testable import RETimeline

// Гейн клипа задаётся в модели, но услышать его можно только на выходе. Этот тест
// читает собранную композицию через тот же AVAssetReaderAudioMixOutput, которым
// пользуется экспорт, и меряет громкость каждого куска.

/// Файл с постоянным тоном: ровный уровень позволяет сравнивать куски напрямую
private func writeTone(seconds: Double, amplitude: Float, to url: URL) async throws {
    let sampleRate = 44100.0
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)

    // Видеодорожка обязательна: сборщик пропускает клип без видео
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 160, AVVideoHeightKey: 160,
    ])
    videoInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    writer.add(videoInput)

    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<Int(seconds * 30) {
        // Ждать готовности обязательно: без проверки вход бросает исключение,
        // и падает не тест, а весь прогон модуля
        while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 160, kCVPixelFormatType_32BGRA, nil, &buffer)
        if let buffer { adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) }
    }
    videoInput.markAsFinished()

    let total = Int(sampleRate * seconds)
    let chunk = 4410
    var written = 0
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                   formatDescriptionOut: &format)

    while written < total {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        let count = min(chunk, total - written)
        var samples = [Float](repeating: amplitude, count: count)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: count * 4, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: count * 4,
            flags: 0, blockBufferOut: &block)
        guard let block else { break }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(
            with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 4) }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                  sampleCount: count, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                  sampleSizeArray: nil, sampleBufferOut: &sample)
        if let sample { input.append(sample) }
        written += count
    }
    input.markAsFinished()
    await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
}

/// Средняя громкость участка собранной композиции — читаем так же, как экспорт
private func rms(_ result: CompositionBuilder.Result, from: Double, to: Double) throws -> Double {
    let reader = try AVAssetReader(asset: result.composition)
    reader.timeRange = CMTimeRange(
        start: CMTime(seconds: from, preferredTimescale: 600),
        duration: CMTime(seconds: to - from, preferredTimescale: 600))

    let tracks = result.composition.tracks(withMediaType: .audio)
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ])
    output.audioMix = result.audioMix
    reader.add(output)
    reader.startReading()

    var sum = 0.0, count = 0
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { continue }
        pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { s in
            for i in 0..<(length / 4) { sum += Double(s[i] * s[i]); count += 1 }
        }
    }
    return count > 0 ? (sum / Double(count)).squareRoot() : 0
}

@Test func clipGainRaisesThatClipOnly() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("tone.mov")
    try await writeTone(seconds: 4, amplitude: 0.1, to: url)

    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first
    let source = MediaSource(
        url: url,
        duration: CMTime(seconds: 4, preferredTimescale: 600),
        naturalSize: try await track?.load(.naturalSize) ?? CGSize(width: 160, height: 160),
        preferredTransform: .identity, nominalFrameRate: 30, hasAudio: true)

    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600))
    let quiet = TimelineClip(sourceID: source.id, availableRange: range, sourceRange: range)
    var loud = TimelineClip(sourceID: source.id, availableRange: range, sourceRange: range)
    loud.gain = 4.0

    var timeline = EditTimeline(sources: [source], clips: [quiet, loud])
    timeline.recalculateOffsets()

    let result = try await CompositionBuilder.build(from: timeline)

    // Середины кусков, подальше от 30-миллисекундных рамп на склейках
    let first = try rms(result, from: 0.4, to: 1.1)
    let second = try rms(result, from: 1.9, to: 2.6)

    #expect(first > 0.001)
    let ratio = second / max(first, 1e-9)
    // Гейн 4 должен дать примерно четырёхкратный уровень
    #expect(ratio > 3.0, "гейн клипа не применился: отношение \(ratio)")
    #expect(ratio < 5.0)
}
