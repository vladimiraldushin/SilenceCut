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

    /// Generate waveform data from a video/audio file.
    /// Streams the audio — peak magnitude per chunk, constant memory.
    public static func generate(from url: URL, samplesPerSecond: Int = 100) async throws -> WaveformData {
        let sampleRate = 44100
        let rawSamplesPerPeak = sampleRate / samplesPerSecond

        var carry: [Float] = []
        var peaks: [Float] = []
        let sampleCount: Int
        do {
            let result = try await AudioSampleStream.read(from: url, sampleRate: sampleRate) { chunk, _ in
                carry.append(contentsOf: chunk)
                var start = 0
                while carry.count - start >= rawSamplesPerPeak {
                    let peak = carry.withUnsafeBufferPointer { buf -> Float in
                        var value: Float = 0
                        if let base = buf.baseAddress {
                            vDSP_maxmgv(base + start, 1, &value, vDSP_Length(rawSamplesPerPeak))
                        }
                        return value
                    }
                    peaks.append(peak)
                    start += rawSamplesPerPeak
                }
                if start > 0 { carry.removeFirst(start) }
            }
            sampleCount = result.sampleCount
        } catch let error as AudioSampleStream.StreamError {
            switch error {
            case .noAudioTrack: throw WaveformError.noAudioTrack
            case .cannotRead: throw WaveformError.cannotRead
            }
        }

        // Tail shorter than a full chunk
        if !carry.isEmpty {
            let peak = carry.withUnsafeBufferPointer { buf -> Float in
                var value: Float = 0
                if let base = buf.baseAddress {
                    vDSP_maxmgv(base, 1, &value, vDSP_Length(buf.count))
                }
                return value
            }
            peaks.append(peak)
        }

        // Normalize to 0-1
        var maxVal: Float = 0
        vDSP_maxv(peaks, 1, &maxVal, vDSP_Length(peaks.count))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(peaks.count))
        }

        let duration = Double(sampleCount) / Double(sampleRate)
        return WaveformData(peaks: peaks, duration: duration, samplesPerSecond: samplesPerSecond)
    }

    public enum WaveformError: Error {
        case noAudioTrack
        case cannotRead
    }
}
