import Foundation
import AVFoundation
import Accelerate
import RECore

/// Generates waveform peak data for timeline visualization
public struct WaveformData {
    public let peaks: [Float]  // normalized 0-1
    public let duration: Double
    public let samplesPerSecond: Int

    public init(peaks: [Float], duration: Double, samplesPerSecond: Int) {
        self.peaks = peaks
        self.duration = duration
        self.samplesPerSecond = samplesPerSecond
    }
}

public enum WaveformGenerator {

    /// Generate waveform data from a video/audio file
    public static func generate(from url: URL, samplesPerSecond: Int = 100) async throws -> WaveformData {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let audioDuration = CMTimeGetSeconds(duration)

        // Configure reader for PCM output
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw WaveformError.cannotRead
        }

        // Read all samples
        let sampleRate = 44100
        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(audioDuration * Double(sampleRate)))

        while let buffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }
            let floatCount = length / MemoryLayout<Float>.size
            data.withUnsafeBytes { rawBuffer in
                guard let floats = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                let buf = UnsafeBufferPointer(start: floats, count: floatCount)
                allSamples.append(contentsOf: buf)
            }
        }

        // Downsample: peak absolute value per chunk
        let rawSamplesPerPeak = sampleRate / samplesPerSecond
        let totalPeaks = Int(audioDuration * Double(samplesPerSecond))
        var peaks = [Float](repeating: 0, count: totalPeaks)

        for i in 0..<totalPeaks {
            let start = i * rawSamplesPerPeak
            let count = min(rawSamplesPerPeak, allSamples.count - start)
            guard count > 0 && start < allSamples.count else { break }

            var absValues = [Float](repeating: 0, count: count)
            vDSP_vabs(Array(allSamples[start..<start+count]), 1, &absValues, 1, vDSP_Length(count))

            var peak: Float = 0
            vDSP_maxv(absValues, 1, &peak, vDSP_Length(count))
            peaks[i] = peak
        }

        // Normalize to 0-1
        var maxVal: Float = 0
        vDSP_maxv(peaks, 1, &maxVal, vDSP_Length(peaks.count))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(peaks.count))
        }

        return WaveformData(peaks: peaks, duration: audioDuration, samplesPerSecond: samplesPerSecond)
    }

    public enum WaveformError: Error {
        case noAudioTrack
        case cannotRead
    }
}
