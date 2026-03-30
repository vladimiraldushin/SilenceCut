import Foundation
import AVFoundation
import CoreMedia
import RECore

/// Фазы транскрибации
public enum TranscriptionPhase: String {
    case downloading = "Загрузка модели..."
    case loading = "Инициализация модели..."
    case transcribing = "Транскрибация..."
}

/// Прогресс транскрибации
public struct TranscriptionProgress {
    public let phase: TranscriptionPhase
    public let fraction: Double
    public let detail: String?

    public init(phase: TranscriptionPhase, fraction: Double, detail: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
    }
}

/// Транскрибирует аудио из видео через ModelManager (WhisperKit / Parakeet)
public enum TranscriptionService {

    public enum TranscriptionError: Error, LocalizedError {
        case noAudioTrack
        case transcriptionFailed(String)
        case modelLoadFailed

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "Нет аудиодорожки в видео"
            case .transcriptionFailed(let msg): return "Ошибка транскрибации: \(msg)"
            case .modelLoadFailed: return "Не удалось загрузить модель"
            }
        }
    }

    /// Transcribe audio from a video file using ModelManager
    /// - Parameters:
    ///   - url: Source video URL
    ///   - modelManager: Manages model lifecycle (download, cache, transcribe)
    ///   - progress: Progress callback
    /// - Returns: Array of SubtitleEntry with word-level timings
    @MainActor
    public static func transcribe(
        url: URL,
        modelManager: ModelManager,
        progress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> [SubtitleEntry] {

        // Step 1: Ensure model is downloaded and loaded (fast if already cached)
        progress(TranscriptionProgress(phase: .downloading, fraction: 0.0))

        try await modelManager.ensureLoaded { frac, detail in
            Task { @MainActor in
                if frac < 1.0 {
                    let phase: TranscriptionPhase = frac < 0.7 ? .downloading : .loading
                    progress(TranscriptionProgress(phase: phase, fraction: frac * 0.5, detail: detail))
                } else {
                    progress(TranscriptionProgress(phase: .loading, fraction: 0.5))
                }
            }
        }

        // Step 2: Transcribe (50% - 95%)
        progress(TranscriptionProgress(phase: .transcribing, fraction: 0.5))

        let segments = try await modelManager.transcribe(audioPath: url.path)

        progress(TranscriptionProgress(phase: .transcribing, fraction: 0.95))

        // Step 3: Convert ASRSegment → SubtitleEntry
        let timescale: CMTimeScale = 600
        var entries: [SubtitleEntry] = []

        for segment in segments {
            let wordTimings: [RECore.WordTiming] = segment.words.map { w in
                RECore.WordTiming(
                    word: w.word,
                    startTime: CMTime(seconds: w.start, preferredTimescale: timescale),
                    endTime: CMTime(seconds: w.end, preferredTimescale: timescale)
                )
            }

            let entry = SubtitleEntry(
                text: segment.text,
                startTime: CMTime(seconds: segment.start, preferredTimescale: timescale),
                endTime: CMTime(seconds: segment.end, preferredTimescale: timescale),
                words: wordTimings
            )

            if !entry.text.isEmpty {
                entries.append(entry)
            }
        }

        progress(TranscriptionProgress(phase: .transcribing, fraction: 1.0))
        print("[Transcription] Complete: \(entries.count) segments, \(entries.flatMap(\.words).count) words")

        return entries
    }
}
