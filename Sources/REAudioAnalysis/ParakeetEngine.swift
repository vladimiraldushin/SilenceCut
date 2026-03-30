import Foundation
import FluidAudio

private extension NSRegularExpression {
    func splitString(_ string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        let matches = self.matches(in: string, range: range)

        var result: [String] = []
        var lastEnd = string.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: string) else { continue }
            let part = String(string[lastEnd..<matchRange.lowerBound])
            if !part.isEmpty { result.append(part) }
            lastEnd = matchRange.upperBound
        }

        let remaining = String(string[lastEnd...])
        if !remaining.isEmpty { result.append(remaining) }

        return result
    }
}

/// Parakeet v3 (NVIDIA) via FluidAudio CoreML — fast on-device ASR with word timestamps
public final class ParakeetEngine: ASREngine {

    private var asrManager: AsrManager?

    public var isLoaded: Bool { asrManager != nil }

    public init() {}

    public func loadModel(variant: String, progress: @escaping (Double, String?) -> Void) async throws {
        progress(0.0, "Загрузка Parakeet v3...")

        // Download CoreML model (~600MB, cached after first download)
        let models = try await AsrModels.downloadAndLoad(version: .v3) { downloadProgress in
            let frac = downloadProgress.fractionCompleted
            let detail: String
            switch downloadProgress.phase {
            case .listing:
                detail = "Поиск файлов..."
            case .downloading(let completed, let total):
                detail = "Файл \(completed)/\(total)"
            case .compiling(let name):
                detail = "Компиляция \(name)..."
            }
            Task { @MainActor in
                progress(frac * 0.8, detail)
            }
        }

        Task { @MainActor in progress(0.8, "Инициализация...") }

        // Initialize ASR manager with higher streaming threshold
        // Default 480k samples (~30s) switches to streaming too early — streaming chunks
        // can miss the beginning of audio. Use 1920000 (~2 min) for batch processing.
        let config = ASRConfig(
            streamingEnabled: true,
            streamingThreshold: 1_920_000  // ~2 minutes at 16kHz
        )
        let manager = AsrManager(config: config)
        try await manager.initialize(models: models)
        asrManager = manager

        Task { @MainActor in progress(1.0, nil) }
        print("[ParakeetEngine] Model loaded")
    }

    public func transcribe(audioPath: String, language: String) async throws -> [ASRSegment] {
        guard let asrManager else {
            throw NSError(domain: "ParakeetEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

        let url = URL(fileURLWithPath: audioPath)
        let result = try await asrManager.transcribe(url, source: .system)

        let timings = result.tokenTimings ?? []
        print("[ParakeetEngine] result.text (first 200): \(String(result.text.prefix(200)))")
        print("[ParakeetEngine] tokens: \(timings.count), first: '\(timings.first?.token ?? "")' \(timings.first?.startTime ?? 0)-\(timings.first?.endTime ?? 0)")

        // Step 1: Merge BPE subtokens into real words using leading-space convention
        let words = mergeTokensIntoWords(timings)
        print("[ParakeetEngine] Merged into \(words.count) words")

        // Step 2: Split words into subtitle-sized segments (by punctuation + max word count)
        let segments = splitWordsIntoSegments(words, maxWordsPerSegment: 8)
        print("[ParakeetEngine] Created \(segments.count) segments")

        return segments
    }

    public func unload() {
        asrManager = nil
        print("[ParakeetEngine] Unloaded")
    }

    // MARK: - Download Only

    /// Download Parakeet model without initializing (for background pre-download)
    public static func downloadOnly(progress: @escaping (Double, String?) -> Void) async throws -> Any {
        progress(0.0, "Загрузка Parakeet v3...")
        let models = try await AsrModels.downloadAndLoad(version: .v3) { downloadProgress in
            let frac = downloadProgress.fractionCompleted
            let detail: String
            switch downloadProgress.phase {
            case .listing:
                detail = "Поиск файлов..."
            case .downloading(let completed, let total):
                detail = "Файл \(completed)/\(total)"
            case .compiling(let name):
                detail = "Компиляция \(name)..."
            }
            Task { @MainActor in
                progress(frac, detail)
            }
        }
        progress(1.0, nil)
        return models
    }

    // MARK: - Token → Word Merging

    /// Merge BPE subtokens into real words using leading-space convention.
    /// Also: strip <unk> tokens, insert space before numbers after letters.
    private func mergeTokensIntoWords(_ tokens: [TokenTiming]) -> [(word: String, start: Double, end: Double)] {
        guard !tokens.isEmpty else { return [] }

        var words: [(word: String, start: Double, end: Double)] = []

        for token in tokens {
            let raw = token.token

            // Strip <unk> entirely
            let cleaned = raw.replacingOccurrences(of: "<unk>", with: "")
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Leading space or sentence-piece marker = new word
            let hasLeadingSpace = cleaned.hasPrefix(" ") || cleaned.hasPrefix("\u{2581}")

            // Also treat as new word if letter↔digit boundary (e.g. "от" + "10" should be separate words)
            let prevEndsWithLetter = words.last?.word.last?.isLetter ?? false
            let startsWithDigit = trimmed.first?.isNumber ?? false
            let prevEndsWithDigit = words.last?.word.last?.isNumber ?? false
            let startsWithLetter = trimmed.first?.isLetter ?? false
            let digitLetterBoundary = (prevEndsWithLetter && startsWithDigit) || (prevEndsWithDigit && startsWithLetter)

            let isNewWord = hasLeadingSpace || digitLetterBoundary || words.isEmpty

            if isNewWord {
                words.append((word: trimmed, start: token.startTime, end: token.endTime))
            } else if !words.isEmpty {
                words[words.count - 1].word += trimmed
                words[words.count - 1].end = token.endTime
            }
        }

        return words
    }

    // MARK: - Word → Segment Splitting

    /// Split word list into subtitle-sized segments.
    /// Split at: sentence punctuation (.!?), commas after 4+ words, or max word limit.
    private func splitWordsIntoSegments(
        _ words: [(word: String, start: Double, end: Double)],
        maxWordsPerSegment: Int
    ) -> [ASRSegment] {
        guard !words.isEmpty else { return [] }

        var segments: [ASRSegment] = []
        var current: [(word: String, start: Double, end: Double)] = []

        for wordInfo in words {
            current.append(wordInfo)

            let word = wordInfo.word
            let endsWithSentence = word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?")
            let endsWithComma = word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":")
            let atLimit = current.count >= maxWordsPerSegment

            // Split after sentence punctuation, or comma if segment already has 4+ words, or at word limit
            let shouldSplit = endsWithSentence || (endsWithComma && current.count >= 4) || atLimit

            if shouldSplit {
                flushSegment(&current, into: &segments)
            }
        }

        // Flush remaining
        flushSegment(&current, into: &segments)

        return segments
    }

    private func flushSegment(
        _ current: inout [(word: String, start: Double, end: Double)],
        into segments: inout [ASRSegment]
    ) {
        guard !current.isEmpty else { return }

        let text = current.map(\.word).joined(separator: " ")
        let start = current.first!.start
        let end = current.last!.end

        segments.append(ASRSegment(
            text: text,
            start: start,
            end: end,
            words: current
        ))

        current = []
    }
}
