import Foundation
import AVFoundation
import Accelerate

/// Generates waveform visualization data from audio tracks using vDSP
actor WaveformGenerator {

    struct WaveformData {
        /// Normalized amplitude samples (0.0 to 1.0) for display
        let samples: [Float]
        /// Duration of the audio in seconds
        let duration: Double
        /// Number of samples per second of audio (display resolution)
        let samplesPerSecond: Int
    }

    enum WaveformError: Error {
        case noAudioTrack
        case cannotRead
        case cancelled
    }

    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    /// Generate waveform data for the given asset
    /// - Parameters:
    ///   - asset: Source video/audio asset
    ///   - samplesPerSecond: Resolution of waveform (default: 100 samples/sec — good for display)
    func generateWaveform(
        from asset: AVAsset,
        samplesPerSecond: Int = 100,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> WaveformData {
        isCancelled = false

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let audioDuration = CMTimeGetSeconds(duration)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WaveformError.cannotRead
        }

        let sampleRate: Double = 44100
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw WaveformError.cannotRead
        }

        // Calculate how many raw samples per waveform sample
        let rawSamplesPerWaveformSample = Int(sampleRate) / samplesPerSecond
        let totalWaveformSamples = Int(audioDuration * Double(samplesPerSecond))

        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(audioDuration * sampleRate))

        // Read all audio data
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if isCancelled { throw WaveformError.cancelled }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }

            let floatCount = length / MemoryLayout<Float>.size
            data.withUnsafeBytes { rawBuffer in
                guard let floats = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                let buffer = UnsafeBufferPointer(start: floats, count: floatCount)
                allSamples.append(contentsOf: buffer)
            }

            let progress = Double(allSamples.count) / (audioDuration * sampleRate)
            progressHandler?(min(progress, 1.0))
        }

        // Downsample using vDSP — take peak absolute value per chunk
        var waveformSamples = [Float](repeating: 0, count: totalWaveformSamples)

        for i in 0..<totalWaveformSamples {
            let start = i * rawSamplesPerWaveformSample
            let count = min(rawSamplesPerWaveformSample, allSamples.count - start)
            guard count > 0 && start < allSamples.count else { break }

            // Get absolute values then find max (peak)
            var absValues = [Float](repeating: 0, count: count)
            vDSP_vabs(Array(allSamples[start..<start+count]), 1, &absValues, 1, vDSP_Length(count))

            var peak: Float = 0
            vDSP_maxv(absValues, 1, &peak, vDSP_Length(count))

            waveformSamples[i] = peak
        }

        // Normalize to 0-1 range
        var maxVal: Float = 0
        vDSP_maxv(waveformSamples, 1, &maxVal, vDSP_Length(waveformSamples.count))

        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(waveformSamples, 1, &scale, &waveformSamples, 1, vDSP_Length(waveformSamples.count))
        }

        return WaveformData(
            samples: waveformSamples,
            duration: audioDuration,
            samplesPerSecond: samplesPerSecond
        )
    }
}
