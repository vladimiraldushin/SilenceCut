import Testing
import Foundation
@testable import REAudioAnalysis

private let testSampleRate = 48000.0

// Синус нужной частоты/амплитуды/длительности — сырой (до K-взвешивания) сигнал для тестов.
private func sineWave(frequency: Double, amplitude: Float, duration: Double) -> [Float] {
    let count = Int(duration * testSampleRate)
    return (0..<count).map { i in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / testSampleRate))
    }
}

@Test func sineWaveLoudnessIsInReasonableRange() {
    // 1 кГц, 3 с, амплитуда 0.5 (mean square = 0.125, т.е. −9.03 dBFS до K-взвешивания).
    // −9.02 LUFS — фактическое значение прогона этого алгоритма (K-фильтр на 1 кГц близок к unity
    // gain, поэтому громкость почти совпадает с dBFS до взвешивания); допуск ±1.0 LU, как просили.
    let signal = sineWave(frequency: 1000, amplitude: 0.5, duration: 3.0)
    let measurement = LoudnessAnalyzer.measure(channels: [signal], sampleRate: testSampleRate)
    #expect(abs(measurement.integratedLUFS - (-9.02)) < 1.0)
}

@Test func doublingAmplitudeAdds6LU() {
    // Удвоение амплитуды => учетверение мощности => +10*log10(4) = +6.02 LU, вне зависимости
    // от формы K-взвешивания (оно линейно, гейтинг при таком сигнале не меняет набор блоков).
    let base = sineWave(frequency: 1000, amplitude: 0.5, duration: 3.0)
    let doubled = sineWave(frequency: 1000, amplitude: 1.0, duration: 3.0)

    let baseMeasurement = LoudnessAnalyzer.measure(channels: [base], sampleRate: testSampleRate)
    let doubledMeasurement = LoudnessAnalyzer.measure(channels: [doubled], sampleRate: testSampleRate)

    #expect(abs((doubledMeasurement.integratedLUFS - baseMeasurement.integratedLUFS) - 6.0) < 0.2)
}

@Test func silenceIsMinus70AndGainIsUnity() {
    let silence = [Float](repeating: 0, count: Int(2.0 * testSampleRate))
    let measurement = LoudnessAnalyzer.measure(channels: [silence], sampleRate: testSampleRate)

    #expect(measurement.integratedLUFS == -70)
    #expect(measurement.peakDBFS == -120)
    #expect(LoudnessAnalyzer.gain(for: measurement) == 1.0)
}

@Test func gatingIgnoresLongSilence() {
    // Громкий кусок (2 с) + длинная тишина (8 с) должны дать почти ту же громкость, что и
    // один громкий кусок без тишины — это и есть смысл гейтинга BS.1770 (тишина не тянет вниз).
    let loud = sineWave(frequency: 1000, amplitude: 0.5, duration: 2.0)
    let silence = [Float](repeating: 0, count: Int(8.0 * testSampleRate))

    let loudOnly = LoudnessAnalyzer.measure(channels: [loud], sampleRate: testSampleRate)
    let loudPlusSilence = LoudnessAnalyzer.measure(channels: [loud + silence], sampleRate: testSampleRate)

    #expect(abs(loudPlusSilence.integratedLUFS - loudOnly.integratedLUFS) < 0.5)
}

@Test func gainTargetsLoudnessAndRespectsCeiling() {
    // −20 LUFS, пик −8 dBFS, цель −14 → нужно +6 дБ; потолок −1 dBFS даёт запас в 7 дБ (−1 − (−8)),
    // это больше желаемых 6 дБ — гейн не ограничивается: pow(10, 6/20) ≈ 1.995.
    let roomyPeak = LoudnessMeasurement(integratedLUFS: -20, peakDBFS: -8, channelCount: 1)
    let roomyGain = LoudnessAnalyzer.gain(for: roomyPeak, targetLUFS: -14, ceilingDBFS: -1)
    #expect(abs(roomyGain - 1.995) < 0.01)

    // Тот же замер, но пик −2 dBFS → запас всего 1 дБ (−1 − (−2)) — гейн ограничен потолком:
    // pow(10, 1/20) ≈ 1.122, а не +6 дБ.
    let tightPeak = LoudnessMeasurement(integratedLUFS: -20, peakDBFS: -2, channelCount: 1)
    let tightGain = LoudnessAnalyzer.gain(for: tightPeak, targetLUFS: -14, ceilingDBFS: -1)
    #expect(abs(tightGain - 1.122) < 0.01)
}

@Test func stereoOfIdenticalChannelsIsLouderThanMonoBy3LU() {
    // Стерео из двух одинаковых каналов суммирует мощность (G=1.0 для L/R) => вдвое больше
    // мощности => +10*log10(2) ≈ +3.01 LU относительно моно того же сигнала.
    let signal = sineWave(frequency: 1000, amplitude: 0.5, duration: 3.0)

    let mono = LoudnessAnalyzer.measure(channels: [signal], sampleRate: testSampleRate)
    let stereo = LoudnessAnalyzer.measure(channels: [signal, signal], sampleRate: testSampleRate)

    #expect(abs((stereo.integratedLUFS - mono.integratedLUFS) - 3.01) < 0.3)
}
