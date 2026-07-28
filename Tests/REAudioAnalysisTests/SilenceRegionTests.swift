import Testing
@testable import REAudioAnalysis

// windowDuration 0.1s, padding 0.25s, минимальная пауза 0.5s
private let settings = SilenceSettings(
    thresholdDB: -35,
    minSilenceDuration: 0.5,
    padding: 0.25,
    windowSize: 4096
)

@Test func allSpeechIsSingleRegion() {
    let isSpeech = [Bool](repeating: true, count: 10)
    let regions = SilenceDetector.speechRegions(
        isSpeech: isSpeech, windowDuration: 0.1, totalDuration: 1.0, settings: settings
    )
    #expect(regions.count == 1)
    #expect(regions[0].startSec == 0)      // padding clamped at 0
    #expect(regions[0].endSec == 1.0)      // padding clamped at totalDuration
}

@Test func longGapProducesTwoRegions() {
    // Speech 0–0.5s, silence 0.5–2.5s, speech 2.5–3.0s.
    // After 0.25s padding the gap is 1.5s ≥ minSilenceDuration → two regions.
    let isSpeech = [Bool](repeating: true, count: 5)
        + [Bool](repeating: false, count: 20)
        + [Bool](repeating: true, count: 5)
    let regions = SilenceDetector.speechRegions(
        isSpeech: isSpeech, windowDuration: 0.1, totalDuration: 3.0, settings: settings
    )
    #expect(regions.count == 2)
    #expect(regions[0].startSec == 0)
    #expect(abs(regions[0].endSec - 0.75) < 0.001)   // 0.5 + padding
    #expect(abs(regions[1].startSec - 2.25) < 0.001) // 2.5 - padding
    #expect(regions[1].endSec == 3.0)
}

@Test func shortGapIsMergedIntoOneRegion() {
    // Silence of 0.3s between speech; padded regions overlap → merged.
    let isSpeech = [Bool](repeating: true, count: 10)
        + [Bool](repeating: false, count: 3)
        + [Bool](repeating: true, count: 10)
    let regions = SilenceDetector.speechRegions(
        isSpeech: isSpeech, windowDuration: 0.1, totalDuration: 2.3, settings: settings
    )
    #expect(regions.count == 1)
    #expect(regions[0].startSec == 0)
    #expect(regions[0].endSec == 2.3)
}

@Test func tooShortSpeechIsFiltered() {
    // A single 0.05s window is below the 0.1s minimum speech duration.
    let isSpeech = [false, true, false, false]
    let regions = SilenceDetector.speechRegions(
        isSpeech: isSpeech, windowDuration: 0.05, totalDuration: 0.2, settings: settings
    )
    #expect(regions.isEmpty)
}

@Test func trailingSpeechEndsAtTotalDuration() {
    // Speech continues to end of file — region must close at totalDuration.
    let isSpeech = [Bool](repeating: false, count: 10) + [Bool](repeating: true, count: 5)
    let regions = SilenceDetector.speechRegions(
        isSpeech: isSpeech, windowDuration: 0.1, totalDuration: 1.5, settings: settings
    )
    #expect(regions.count == 1)
    #expect(abs(regions[0].startSec - 0.75) < 0.001) // 1.0 - padding
    #expect(regions[0].endSec == 1.5)
}
