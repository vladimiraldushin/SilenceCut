import Foundation
import AVFoundation
import Accelerate
import CoreMedia

/// Parameters for silence detection
public struct SilenceSettings: Codable, Equatable {
    /// RMS threshold in dBFS (e.g. -35 means sounds below -35 dBFS are silence)
    public var thresholdDB: Float
    /// Minimum silence duration to detect (seconds)
    public var minSilenceDuration: Double
    /// Padding added to each side of speech regions (seconds)
    public var padding: Double
    /// RMS analysis window size (samples)
    public var windowSize: Int

    public init(
        thresholdDB: Float = -35,
        minSilenceDuration: Double = 0.5,
        padding: Double = 0.25,
        windowSize: Int = 4096
    ) {
        self.thresholdDB = thresholdDB
        self.minSilenceDuration = minSilenceDuration
        self.padding = padding
        self.windowSize = windowSize
    }

    // Presets
    public static let aggressive = SilenceSettings(thresholdDB: -30, minSilenceDuration: 0.3, padding: 0.15)
    public static let normal = SilenceSettings(thresholdDB: -35, minSilenceDuration: 0.5, padding: 0.25)
    public static let conservative = SilenceSettings(thresholdDB: -40, minSilenceDuration: 0.8, padding: 0.35)
}

/// Result of silence detection
public struct SilenceDetectionResult {
    /// Speech regions (only these will become clips)
    public let speechRanges: [CMTimeRange]
    /// Silence regions (for visualization)
    public let silenceRanges: [CMTimeRange]
    /// Total silence duration
    public let totalSilenceDuration: Double
    /// Total speech duration
    public let totalSpeechDuration: Double
    /// Number of pauses found
    public let pauseCount: Int
}

/// Detects silence in audio using vDSP RMS analysis (Accelerate framework, Apple Silicon optimized)
public enum SilenceDetector {

    public enum DetectionError: Error, LocalizedError {
        case noAudioTrack
        case cannotRead
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "No audio track in video"
            case .cannotRead: return "Cannot read audio data"
            case .cancelled: return "Detection cancelled"
            }
        }
    }

    /// Detect silence in an audio/video file
    /// - Parameters:
    ///   - url: Source file URL
    ///   - settings: Detection parameters
    ///   - progress: Optional progress callback (0.0-1.0)
    /// - Returns: SilenceDetectionResult with speech and silence ranges
    public static func detect(
        in url: URL,
        settings: SilenceSettings = .normal,
        progress: ((Double) -> Void)? = nil
    ) async throws -> SilenceDetectionResult {
        let sampleRate: Int = 44100

        // 1. Read audio samples via AVAssetReader
        let samples = try await readAudioSamples(from: url, sampleRate: sampleRate)
        progress?(0.3)

        // 2. RMS analysis with vDSP
        let windowSize = settings.windowSize
        let windowDuration = Double(windowSize) / Double(sampleRate)
        let totalWindows = (samples.count - windowSize) / windowSize + 1
        guard totalWindows > 0 else {
            throw DetectionError.cannotRead
        }

        // Compute RMS for each window
        var rmsValues = [Float](repeating: 0, count: totalWindows)
        for i in 0..<totalWindows {
            let start = i * windowSize
            let end = min(start + windowSize, samples.count)
            let count = end - start
            guard count > 0 else { break }

            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var rms: Float = 0
                vDSP_rmsqv(base.advanced(by: start), 1, &rms, vDSP_Length(count))
                rmsValues[i] = rms
            }
        }
        progress?(0.6)

        // 3. Classify each window as speech or silence
        let thresholdLinear = powf(10.0, settings.thresholdDB / 20.0)
        var isSpeech = [Bool](repeating: false, count: totalWindows)
        for i in 0..<totalWindows {
            isSpeech[i] = rmsValues[i] >= thresholdLinear
        }

        // 4. Find speech regions with hysteresis
        var rawSpeechRegions: [(startSec: Double, endSec: Double)] = []
        var regionStart: Int? = nil

        for i in 0..<totalWindows {
            if isSpeech[i] {
                if regionStart == nil { regionStart = i }
            } else if let start = regionStart {
                let startSec = Double(start) * windowDuration
                let endSec = Double(i) * windowDuration
                let duration = endSec - startSec
                // Minimum speech duration filter (100ms)
                if duration >= 0.1 {
                    rawSpeechRegions.append((startSec, endSec))
                }
                regionStart = nil
            }
        }
        // Handle speech at end of file
        if let start = regionStart {
            let startSec = Double(start) * windowDuration
            let endSec = Double(samples.count) / Double(sampleRate)
            if endSec - startSec >= 0.1 {
                rawSpeechRegions.append((startSec, endSec))
            }
        }
        progress?(0.8)

        // 5. Apply padding and merge overlapping regions
        let totalDuration = Double(samples.count) / Double(sampleRate)
        var paddedRegions: [(startSec: Double, endSec: Double)] = []
        for region in rawSpeechRegions {
            let paddedStart = max(0, region.startSec - settings.padding)
            let paddedEnd = min(totalDuration, region.endSec + settings.padding)
            paddedRegions.append((paddedStart, paddedEnd))
        }

        // Merge overlapping
        var merged: [(startSec: Double, endSec: Double)] = []
        for region in paddedRegions {
            if let last = merged.last, region.startSec <= last.endSec {
                merged[merged.count - 1].endSec = max(last.endSec, region.endSec)
            } else {
                merged.append(region)
            }
        }

        // 6. Filter: only keep silences >= minSilenceDuration
        // Re-merge speech regions that were separated by short silences
        var finalSpeech: [(startSec: Double, endSec: Double)] = []
        for region in merged {
            if let last = finalSpeech.last {
                let gap = region.startSec - last.endSec
                if gap < settings.minSilenceDuration {
                    // Gap too short — merge with previous speech
                    finalSpeech[finalSpeech.count - 1].endSec = region.endSec
                } else {
                    finalSpeech.append(region)
                }
            } else {
                finalSpeech.append(region)
            }
        }

        // 7. Convert to CMTimeRange
        let timescale: CMTimeScale = 600
        let speechRanges: [CMTimeRange] = finalSpeech.map { region in
            CMTimeRange(
                start: CMTime(seconds: region.startSec, preferredTimescale: timescale),
                duration: CMTime(seconds: region.endSec - region.startSec, preferredTimescale: timescale)
            )
        }

        // Calculate silence ranges (gaps between speech)
        var silenceRanges: [CMTimeRange] = []
        var prevEnd: Double = 0
        for region in finalSpeech {
            if region.startSec > prevEnd + 0.01 {
                silenceRanges.append(CMTimeRange(
                    start: CMTime(seconds: prevEnd, preferredTimescale: timescale),
                    duration: CMTime(seconds: region.startSec - prevEnd, preferredTimescale: timescale)
                ))
            }
            prevEnd = region.endSec
        }
        // Trailing silence
        if prevEnd < totalDuration - 0.01 {
            silenceRanges.append(CMTimeRange(
                start: CMTime(seconds: prevEnd, preferredTimescale: timescale),
                duration: CMTime(seconds: totalDuration - prevEnd, preferredTimescale: timescale)
            ))
        }

        let totalSilence = silenceRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        let totalSpeech = speechRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }

        progress?(1.0)

        return SilenceDetectionResult(
            speechRanges: speechRanges,
            silenceRanges: silenceRanges,
            totalSilenceDuration: totalSilence,
            totalSpeechDuration: totalSpeech,
            pauseCount: silenceRanges.count
        )
    }

    // MARK: - Audio Reading

    private static func readAudioSamples(from url: URL, sampleRate: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DetectionError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let audioDuration = CMTimeGetSeconds(duration)

        let reader = try AVAssetReader(asset: asset)
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
            throw DetectionError.cannotRead
        }

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

        return allSamples
    }
}
