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
        let windowSize = settings.windowSize
        let windowDuration = Double(windowSize) / Double(sampleRate)

        // 1-2. Stream audio and compute per-window RMS on the fly (constant memory)
        var carry: [Float] = []
        var rmsValues: [Float] = []
        let sampleCount: Int
        do {
            let result = try await AudioSampleStream.read(from: url, sampleRate: sampleRate) { chunk, fraction in
                carry.append(contentsOf: chunk)
                var start = 0
                while carry.count - start >= windowSize {
                    let rms = carry.withUnsafeBufferPointer { buf -> Float in
                        var value: Float = 0
                        if let base = buf.baseAddress {
                            vDSP_rmsqv(base + start, 1, &value, vDSP_Length(windowSize))
                        }
                        return value
                    }
                    rmsValues.append(rms)
                    start += windowSize
                }
                if start > 0 { carry.removeFirst(start) }
                progress?(fraction * 0.6)
            }
            sampleCount = result.sampleCount
        } catch let error as AudioSampleStream.StreamError {
            switch error {
            case .noAudioTrack: throw DetectionError.noAudioTrack
            case .cannotRead: throw DetectionError.cannotRead
            }
        }
        guard !rmsValues.isEmpty else {
            throw DetectionError.cannotRead
        }
        let totalDuration = Double(sampleCount) / Double(sampleRate)
        progress?(0.7)

        // 3. Classify each window as speech or silence
        let thresholdLinear = powf(10.0, settings.thresholdDB / 20.0)
        let isSpeech = rmsValues.map { $0 >= thresholdLinear }

        // 4-6. Build speech regions (pure logic, unit-tested)
        let finalSpeech = speechRegions(
            isSpeech: isSpeech,
            windowDuration: windowDuration,
            totalDuration: totalDuration,
            settings: settings
        )
        progress?(0.9)

        // 7. Convert to CMTimeRange + silence gaps + totals (shared with detect(cache:))
        let result = buildResult(finalSpeech: finalSpeech, totalDuration: totalDuration)
        progress?(1.0)
        return result
    }

    /// Мгновенный пересчёт тишины по уже готовому `RMSCache` — без повторного чтения файла.
    /// Использует ту же классификацию окон и построение регионов/результата, что и
    /// `detect(in:settings:progress:)` (через общий `buildResult`), поэтому оба пути при
    /// одинаковых данных (RMS-окна/windowDuration/totalDuration) и настройках дают идентичный результат.
    public static func detect(cache: RMSCache, settings: SilenceSettings) -> SilenceDetectionResult {
        // 3. Classify each window as speech or silence
        let thresholdLinear = powf(10.0, settings.thresholdDB / 20.0)
        let isSpeech = cache.rmsValues.map { $0 >= thresholdLinear }

        // 4-6. Build speech regions (pure logic, unit-tested)
        let finalSpeech = speechRegions(
            isSpeech: isSpeech,
            windowDuration: cache.windowDuration,
            totalDuration: cache.totalDuration,
            settings: settings
        )

        // 7. Convert to CMTimeRange + silence gaps + totals (shared with detect(in:))
        return buildResult(finalSpeech: finalSpeech, totalDuration: cache.totalDuration)
    }

    // MARK: - Region Building (pure, testable)

    /// Строит речевые регионы из классифицированных окон:
    /// окна → сырые регионы (мин. 100 мс) → padding → слияние пересечений →
    /// склейка регионов, разделённых паузами короче minSilenceDuration.
    static func speechRegions(
        isSpeech: [Bool],
        windowDuration: Double,
        totalDuration: Double,
        settings: SilenceSettings
    ) -> [(startSec: Double, endSec: Double)] {
        // Raw regions with minimum speech duration filter (100ms)
        var rawSpeechRegions: [(startSec: Double, endSec: Double)] = []
        var regionStart: Int? = nil

        for i in 0..<isSpeech.count {
            if isSpeech[i] {
                if regionStart == nil { regionStart = i }
            } else if let start = regionStart {
                let startSec = Double(start) * windowDuration
                let endSec = Double(i) * windowDuration
                if endSec - startSec >= 0.1 {
                    rawSpeechRegions.append((startSec, endSec))
                }
                regionStart = nil
            }
        }
        // Speech at end of file
        if let start = regionStart {
            let startSec = Double(start) * windowDuration
            if totalDuration - startSec >= 0.1 {
                rawSpeechRegions.append((startSec, totalDuration))
            }
        }

        // Apply padding and merge overlapping regions
        var merged: [(startSec: Double, endSec: Double)] = []
        for region in rawSpeechRegions {
            let paddedStart = max(0, region.startSec - settings.padding)
            let paddedEnd = min(totalDuration, region.endSec + settings.padding)
            if let last = merged.last, paddedStart <= last.endSec {
                merged[merged.count - 1].endSec = max(last.endSec, paddedEnd)
            } else {
                merged.append((paddedStart, paddedEnd))
            }
        }

        // Re-merge speech regions separated by silences shorter than minSilenceDuration
        var finalSpeech: [(startSec: Double, endSec: Double)] = []
        for region in merged {
            if let last = finalSpeech.last, region.startSec - last.endSec < settings.minSilenceDuration {
                finalSpeech[finalSpeech.count - 1].endSec = region.endSec
            } else {
                finalSpeech.append(region)
            }
        }
        return finalSpeech
    }

    // MARK: - Result Building (pure, testable)

    /// Конвертирует речевые регионы (в секундах) в `SilenceDetectionResult`: CMTimeRange для речи,
    /// паузы-тишина между регионами (и в начале/конце файла), суммарные длительности.
    /// Общий helper для `detect(in:settings:progress:)` и `detect(cache:settings:)` — гарантирует,
    /// что оба пути строят результат идентично.
    private static func buildResult(
        finalSpeech: [(startSec: Double, endSec: Double)],
        totalDuration: Double
    ) -> SilenceDetectionResult {
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

        return SilenceDetectionResult(
            speechRanges: speechRanges,
            silenceRanges: silenceRanges,
            totalSilenceDuration: totalSilence,
            totalSpeechDuration: totalSpeech,
            pauseCount: silenceRanges.count
        )
    }
}
