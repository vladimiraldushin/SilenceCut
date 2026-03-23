import Foundation
import AVFoundation
import CoreMedia
import RECore
import WhisperKit

/// Progress phases for transcription
public enum TranscriptionPhase: String {
    case downloading = "Downloading model..."
    case loading = "Loading model..."
    case transcribing = "Transcribing..."
}

/// Progress info
public struct TranscriptionProgress {
    public let phase: TranscriptionPhase
    public let fraction: Double
}

/// Transcribes audio from video using WhisperKit (Apple Silicon Neural Engine)
public enum TranscriptionService {

    public enum TranscriptionError: Error, LocalizedError {
        case noAudioTrack
        case transcriptionFailed(String)
        case modelLoadFailed

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "No audio track in video"
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            case .modelLoadFailed: return "Failed to load WhisperKit model"
            }
        }
    }

    /// Transcribe audio from a video file
    /// - Parameters:
    ///   - url: Source video URL
    ///   - language: Language code (e.g. "ru", "en")
    ///   - modelName: WhisperKit model name (default: large-v3)
    ///   - progress: Progress callback
    /// - Returns: Array of SubtitleEntry with word-level timings
    public static func transcribe(
        url: URL,
        language: String = "ru",
        modelName: String = "large-v3",
        progress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> [SubtitleEntry] {
        progress(TranscriptionProgress(phase: .loading, fraction: 0.1))

        // Initialize WhisperKit
        let config = WhisperKitConfig(model: modelName)
        let whisperKit = try await WhisperKit(config)

        progress(TranscriptionProgress(phase: .transcribing, fraction: 0.3))

        // Configure decoding
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            wordTimestamps: true
        )

        // Transcribe
        let results = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: options
        )

        progress(TranscriptionProgress(phase: .transcribing, fraction: 0.9))

        // Convert WhisperKit results to our SubtitleEntry model
        var entries: [SubtitleEntry] = []
        let timescale: CMTimeScale = 600

        for result in results {
            for segment in result.segments {
                var wordTimings: [RECore.WordTiming] = []

                if let words = segment.words {
                    for wt in words {
                        let cleaned = Self.stripTokens(wt.word)
                        guard !cleaned.isEmpty else { continue }
                        wordTimings.append(RECore.WordTiming(
                            word: cleaned,
                            startTime: CMTime(seconds: Double(wt.start), preferredTimescale: timescale),
                            endTime: CMTime(seconds: Double(wt.end), preferredTimescale: timescale)
                        ))
                    }
                }

                let cleanedText = Self.stripTokens(segment.text)
                let entry = SubtitleEntry(
                    text: cleanedText,
                    startTime: CMTime(seconds: Double(segment.start), preferredTimescale: timescale),
                    endTime: CMTime(seconds: Double(segment.end), preferredTimescale: timescale),
                    words: wordTimings
                )

                // Skip empty segments
                if !entry.text.isEmpty {
                    entries.append(entry)
                }
            }
        }

        progress(TranscriptionProgress(phase: .transcribing, fraction: 1.0))

        print("[Transcription] Complete: \(entries.count) segments, \(entries.flatMap(\.words).count) words")

        return entries
    }

    /// Strip WhisperKit control tokens like <|startoftranscript|>, <|ru|>, <|0.00|>, etc.
    private static func stripTokens(_ text: String) -> String {
        // Use regex to safely remove all <|...|> tokens
        let cleaned = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
