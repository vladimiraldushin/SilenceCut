import Foundation

/// Settings for silence detection algorithm
struct SilenceDetectionSettings: Codable, Equatable {
    /// Volume threshold in decibels. Sounds below this level are considered silence.
    /// Range: -60 to 0 dB. Default: -30 dB
    var thresholdDB: Float = -30.0

    /// Minimum duration of silence to detect (in seconds).
    /// Shorter pauses will be ignored. Default: 0.3s
    var minDurationSec: Double = 0.3

    /// Padding in milliseconds added to speech boundaries.
    /// Prevents cutting speech too aggressively. Default: 100ms
    var paddingMs: Int = 100

    var paddingSec: Double {
        Double(paddingMs) / 1000.0
    }

    /// Predefined presets
    static let aggressive = SilenceDetectionSettings(thresholdDB: -25, minDurationSec: 0.2, paddingMs: 50)
    static let normal = SilenceDetectionSettings(thresholdDB: -30, minDurationSec: 0.3, paddingMs: 100)
    static let conservative = SilenceDetectionSettings(thresholdDB: -40, minDurationSec: 0.5, paddingMs: 200)
}
