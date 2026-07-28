import Foundation
import AVFoundation
import CoreMedia

/// Потоковое чтение аудио (mono Float32) чанками — без загрузки всего трека в память.
/// Используется SilenceDetector и WaveformGenerator.
enum AudioSampleStream {

    enum StreamError: Error {
        case noAudioTrack
        case cannotRead
    }

    /// Читает аудиодорожку и вызывает `onSamples(chunk, fractionRead)` по мере чтения.
    /// Возвращает фактическое число прочитанных сэмплов и длительность ассета.
    @discardableResult
    static func read(
        from url: URL,
        sampleRate: Int,
        onSamples: ([Float], Double) -> Void
    ) async throws -> (sampleCount: Int, assetDuration: Double) {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw StreamError.noAudioTrack
        }
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))
        let expectedSamples = max(assetDuration * Double(sampleRate), 1)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw StreamError.cannotRead
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw StreamError.cannotRead
        }

        var totalSamples = 0
        while let buffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            var chunk = [Float](repeating: 0, count: floatCount)
            chunk.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }
            totalSamples += floatCount
            onSamples(chunk, min(Double(totalSamples) / expectedSamples, 1.0))
        }

        if reader.status == .failed {
            throw StreamError.cannotRead
        }
        return (totalSamples, assetDuration)
    }
}
