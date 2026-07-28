import Testing
import CoreMedia
@testable import REAudioAnalysis

// windowDuration 0.1s, padding 0.25s, минимальная пауза 0.5s — как в SilenceRegionTests
private let settings = SilenceSettings(
    thresholdDB: -35,
    minSilenceDuration: 0.5,
    padding: 0.25,
    windowSize: 4096
)

@Test func detectFromCacheBuildsSpeechAndSilenceRanges() {
    // Громко (0.5) 5 окон, тихо (0.0001) 20 окон, громко (0.5) 5 окон — 0.1s/окно, totalDuration 3.0s.
    // Форма совпадает с SilenceRegionTests.longGapProducesTwoRegions: после паддинга 0.25s
    // пауза (0.5–2.5s) остаётся ≥ minSilenceDuration → два речевых региона.
    let rmsValues = [Float](repeating: 0.5, count: 5)
        + [Float](repeating: 0.0001, count: 20)
        + [Float](repeating: 0.5, count: 5)
    let cache = RMSCache(rmsValues: rmsValues, windowDuration: 0.1, totalDuration: 3.0)

    let result = SilenceDetector.detect(cache: cache, settings: settings)

    #expect(result.speechRanges.count == 2)
    #expect(result.speechRanges[0].start.seconds == 0)
    #expect(abs(result.speechRanges[0].duration.seconds - 0.75) < 0.001)         // 0.5 + padding
    #expect(abs(result.speechRanges[1].start.seconds - 2.25) < 0.001)            // 2.5 - padding
    #expect(abs((result.speechRanges[1].start + result.speechRanges[1].duration).seconds - 3.0) < 0.001)

    #expect(result.silenceRanges.count == 1)
    #expect(abs(result.silenceRanges[0].start.seconds - 0.75) < 0.001)
    #expect(abs((result.silenceRanges[0].start + result.silenceRanges[0].duration).seconds - 2.25) < 0.001)
    #expect(result.pauseCount == result.silenceRanges.count)

    #expect(abs(result.totalSpeechDuration - 1.5) < 0.001)
    #expect(abs(result.totalSilenceDuration - 1.5) < 0.001)
    #expect(abs(result.totalSilenceDuration + result.totalSpeechDuration - cache.totalDuration) < 0.001)
}

@Test func higherThresholdProducesMoreSilence() {
    // Громко (0.5) x5, средне (0.05 ≈ -26 dB) x5, тихо (0.0001) x20, громко (0.5) x5 — 0.1s/окно.
    let rmsValues = [Float](repeating: 0.5, count: 5)
        + [Float](repeating: 0.05, count: 5)
        + [Float](repeating: 0.0001, count: 20)
        + [Float](repeating: 0.5, count: 5)
    let cache = RMSCache(rmsValues: rmsValues, windowDuration: 0.1, totalDuration: 3.5)

    // -35dB (порог ниже): участок 0.05 классифицируется как речь.
    let lenient = SilenceSettings(thresholdDB: -35, minSilenceDuration: 0.5, padding: 0.25, windowSize: 4096)
    // -20dB (порог выше, линейно ≈0.1): участок 0.05 уже классифицируется как тишина.
    let strict = SilenceSettings(thresholdDB: -20, minSilenceDuration: 0.5, padding: 0.25, windowSize: 4096)

    let lenientResult = SilenceDetector.detect(cache: cache, settings: lenient)
    let strictResult = SilenceDetector.detect(cache: cache, settings: strict)

    #expect(abs(lenientResult.totalSilenceDuration - 1.5) < 0.001)
    #expect(abs(lenientResult.totalSpeechDuration - 2.0) < 0.001)

    #expect(abs(strictResult.totalSilenceDuration - 2.0) < 0.001)
    #expect(abs(strictResult.totalSpeechDuration - 1.5) < 0.001)

    // Порог выше → больше тишины (и меньше речи) на одном и том же кеше.
    #expect(strictResult.totalSilenceDuration > lenientResult.totalSilenceDuration)
    #expect(strictResult.totalSpeechDuration < lenientResult.totalSpeechDuration)
}

@Test func emptyCacheHasNoSpeechAndIsAllSilence() {
    // Пустой кеш (например, файл короче одного RMS-окна) — вся длительность в тишине.
    let cache = RMSCache(rmsValues: [], windowDuration: 0.1, totalDuration: 0.05)

    let result = SilenceDetector.detect(cache: cache, settings: settings)

    #expect(result.speechRanges.isEmpty)
    #expect(result.silenceRanges.count == 1)
    #expect(result.silenceRanges[0].start.seconds == 0)
    #expect(abs(result.silenceRanges[0].duration.seconds - cache.totalDuration) < 0.0001)
    #expect(result.totalSpeechDuration == 0)
    #expect(abs(result.totalSilenceDuration - cache.totalDuration) < 0.0001)
}

@Test func fullySilentCacheHasNoSpeechAndIsAllSilence() {
    // Все окна тише порога — вся длительность в тишине, независимо от количества окон.
    let rmsValues = [Float](repeating: 0.0001, count: 10)
    let cache = RMSCache(rmsValues: rmsValues, windowDuration: 0.1, totalDuration: 1.0)

    let result = SilenceDetector.detect(cache: cache, settings: settings)

    #expect(result.speechRanges.isEmpty)
    #expect(result.silenceRanges.count == 1)
    #expect(result.silenceRanges[0].start.seconds == 0)
    #expect(abs(result.silenceRanges[0].duration.seconds - 1.0) < 0.001)
    #expect(result.totalSpeechDuration == 0)
    #expect(abs(result.totalSilenceDuration - 1.0) < 0.001)
    #expect(result.pauseCount == 1)
}
