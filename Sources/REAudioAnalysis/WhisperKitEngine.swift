import Foundation
import WhisperKit

/// WhisperKit wrapper conforming to ASREngine protocol
public final class WhisperKitEngine: ASREngine {

    private var whisperKit: WhisperKit?

    public var isLoaded: Bool { whisperKit != nil }

    public init() {}

    public func loadModel(variant: String, progress: @escaping (Double, String?) -> Void) async throws {
        // Step 1: Download (idempotent — returns cache path instantly if already downloaded)
        let modelFolder = try await WhisperKit.download(
            variant: "openai_whisper-\(variant)",
            progressCallback: { downloadProgress in
                let frac = downloadProgress.fractionCompleted
                let downloaded = downloadProgress.completedUnitCount
                let total = downloadProgress.totalUnitCount

                let detail: String
                if total > 0 {
                    let downloadedMB = Double(downloaded) / 1_048_576
                    let totalMB = Double(total) / 1_048_576
                    detail = String(format: "%.0f / %.0f МБ", downloadedMB, totalMB)
                } else {
                    let downloadedMB = Double(downloaded) / 1_048_576
                    detail = String(format: "%.0f МБ", downloadedMB)
                }

                Task { @MainActor in
                    progress(frac * 0.7, detail)
                }
            }
        )
        print("[WhisperKitEngine] Model downloaded: \(modelFolder.path)")

        // Step 2: Initialize WhisperKit
        Task { @MainActor in progress(0.8, nil) }

        let config = WhisperKitConfig(modelFolder: modelFolder.path)
        whisperKit = try await WhisperKit(config)

        Task { @MainActor in progress(1.0, nil) }
        print("[WhisperKitEngine] Model initialized")
    }

    public func transcribe(audioPath: String, language: String) async throws -> [ASRSegment] {
        guard let whisperKit else {
            throw NSError(domain: "WhisperKitEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

        let lang: String? = language == "auto" ? nil : language
        let options = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperature: 0.0,
            wordTimestamps: true
        )

        let results = try await whisperKit.transcribe(audioPath: audioPath, decodeOptions: options)

        var segments: [ASRSegment] = []
        for result in results {
            // result.text is decoded from ALL tokens at once — should be the most reliable source
            let fullText = stripTokens(result.text)
            print("[WhisperKit] result.text (first 200 chars): \(String(fullText.prefix(200)))")

            for (idx, segment) in result.segments.enumerated() {
                let rawText = stripTokens(segment.text)
                print("[WhisperKit] segment[\(idx)].text: '\(rawText)'")

                // Detect if segment.text has broken Cyrillic (subtokens with spaces)
                // Heuristic: if average "word" length < 3 chars, text is likely broken subtokens
                let textToUse: String
                let splitWords = rawText.split(separator: " ")
                let avgWordLen = splitWords.isEmpty ? 0 : splitWords.reduce(0) { $0 + $1.count } / splitWords.count

                if avgWordLen < 3 && !rawText.isEmpty {
                    // segment.text is broken — reconstruct by removing spurious spaces
                    // between Cyrillic characters that are clearly subtokens
                    let fixed = fixBrokenCyrillicText(rawText)
                    print("[WhisperKit] FIXED segment[\(idx)]: '\(fixed)'")
                    textToUse = fixed
                } else {
                    textToUse = rawText
                }

                guard !textToUse.isEmpty else { continue }

                let words = distributeWordTimings(
                    segmentText: textToUse,
                    segmentStart: Double(segment.start),
                    segmentEnd: Double(segment.end),
                    tokenTimings: segment.words ?? []
                )

                segments.append(ASRSegment(
                    text: textToUse,
                    start: Double(segment.start),
                    end: Double(segment.end),
                    words: words
                ))
            }
        }

        return segments
    }

    public func unload() {
        whisperKit = nil
        print("[WhisperKitEngine] Unloaded")
    }

    // MARK: - Download Only (no init)

    /// Download model files without initializing WhisperKit (for background pre-download)
    public static func downloadOnly(variant: String, progress: @escaping (Double, String?) -> Void) async throws -> URL {
        let modelFolder = try await WhisperKit.download(
            variant: "openai_whisper-\(variant)",
            progressCallback: { downloadProgress in
                let frac = downloadProgress.fractionCompleted
                let downloaded = downloadProgress.completedUnitCount
                let total = downloadProgress.totalUnitCount
                let detail: String
                if total > 0 {
                    let downloadedMB = Double(downloaded) / 1_048_576
                    let totalMB = Double(total) / 1_048_576
                    detail = String(format: "%.0f / %.0f МБ", downloadedMB, totalMB)
                } else {
                    let downloadedMB = Double(downloaded) / 1_048_576
                    detail = String(format: "%.0f МБ", downloadedMB)
                }
                Task { @MainActor in
                    progress(frac, detail)
                }
            }
        )
        return modelFolder
    }

    // MARK: - Word Timing Distribution

    /// WhisperKit word timestamps are broken for Cyrillic/Russian — each BPE byte-pair becomes
    /// a separate "word" (e.g. "Е", "сли" instead of "Если"). The segment.text is correct though.
    ///
    /// Strategy: split segment.text into real words, then use token timings to estimate
    /// time for each word proportionally by character count.
    private func distributeWordTimings(
        segmentText: String,
        segmentStart: Double,
        segmentEnd: Double,
        tokenTimings: [WordTiming]
    ) -> [(word: String, start: Double, end: Double)] {
        let realWords = segmentText.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !realWords.isEmpty else { return [] }

        let totalChars = realWords.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else { return [] }

        let duration = segmentEnd - segmentStart
        var result: [(word: String, start: Double, end: Double)] = []
        var currentTime = segmentStart

        for word in realWords {
            let fraction = Double(word.count) / Double(totalChars)
            let wordDuration = duration * fraction
            let wordEnd = min(currentTime + wordDuration, segmentEnd)
            result.append((word: word, start: currentTime, end: wordEnd))
            currentTime = wordEnd
        }

        return result
    }

    // MARK: - Cyrillic Text Fixer

    /// WhisperKit's BPE tokenizer breaks Cyrillic text into byte-level subtokens.
    /// segment.text may contain "Е сли вы И П или само за ня ты й" instead of "Если вы ИП или самозанятый".
    ///
    /// Strategy: remove spaces that appear between characters that should be part of the same word.
    /// A space is spurious if:
    ///   - It's between two Cyrillic characters where the right one is lowercase, OR
    ///   - It's between two Cyrillic uppercase characters that form a known pattern (acronyms like "ИП")
    ///
    /// We iterate character-by-character and only keep spaces that look like real word boundaries:
    /// a space followed by a lowercase Cyrillic letter after another Cyrillic letter = subtoken break → remove space
    /// a space followed by an uppercase after lowercase = real word boundary → keep space
    private func fixBrokenCyrillicText(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count > 2 else { return text }

        var result = String(chars[0])

        for i in 1..<chars.count {
            let current = chars[i]
            let prev = chars[i - 1]

            if prev == " " {
                // Decide whether this space is real or spurious
                let beforeSpace: Character? = i >= 2 ? chars[i - 2] : nil

                if let before = beforeSpace, isCyrillic(before) && isCyrillic(current) {
                    if current.isLowercase {
                        // "а сли" → "асли" (lowercase after Cyrillic = subtoken, remove space)
                        // But DON'T remove if 'before' ended a real word — check previous context
                        // Heuristic: if the chunk before space is very short (1-2 chars), it's a subtoken
                        let chunkLen = lastWordLength(in: result)
                        if chunkLen <= 3 {
                            // Short chunk + lowercase continuation = subtoken → remove space
                            result.removeLast() // remove the space we already added
                            result.append(current)
                            continue
                        }
                    } else if current.isUppercase {
                        // "И П" → could be "ИП" (acronym) or "И Привет" (real boundary)
                        // If both are single uppercase chars, likely acronym → remove space
                        let chunkLen = lastWordLength(in: result)
                        if chunkLen == 1 && before.isUppercase {
                            result.removeLast() // remove space
                            result.append(current)
                            continue
                        }
                    }
                }
            }

            result.append(current)
        }

        return result
    }

    private func isCyrillic(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        // Cyrillic: U+0400-U+04FF
        return (0x0400...0x04FF).contains(scalar.value)
    }

    /// Length of the last "word" (characters since last space) in the string
    private func lastWordLength(in s: String) -> Int {
        var count = 0
        for c in s.reversed() {
            if c == " " { break }
            count += 1
        }
        return count
    }

    // MARK: - Helpers

    private func stripTokens(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
