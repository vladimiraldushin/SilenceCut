import Foundation
import Accelerate

/// Кеш RMS-окон — позволяет мгновенно пересчитывать детекцию тишины при смене настроек без перечитывания файла
public struct RMSCache: Sendable {
    public let rmsValues: [Float]
    public let windowDuration: Double   // сек на окно
    public let totalDuration: Double    // сек всего

    public init(rmsValues: [Float], windowDuration: Double, totalDuration: Double) {
        self.rmsValues = rmsValues
        self.windowDuration = windowDuration
        self.totalDuration = totalDuration
    }
}

/// Комбинированный потоковый анализ аудио: считает waveform-пики (для таймлайна) и
/// RMS-окна (для мгновенного пересчёта тишины через `SilenceDetector.detect(cache:settings:)`)
/// за ОДИН проход по файлу — вместо двух отдельных чтений в `WaveformGenerator.generate`
/// и `SilenceDetector.detect(in:)`.
public enum AudioAnalysis {

    /// Отдельный enum ошибок для `analyze`: он не привязан ни к waveform-, ни к silence-API,
    /// поэтому не переиспользует `WaveformGenerator.WaveformError` / `SilenceDetector.DetectionError`,
    /// а просто зеркалит случаи `AudioSampleStream.StreamError` в своём неймспейсе.
    public enum AnalysisError: Error {
        case noAudioTrack
        case cannotRead
    }

    /// ОДИН потоковый проход по аудио: waveform-пики + RMS-окна одновременно.
    /// - Parameters:
    ///   - url: исходный видео/аудио файл
    ///   - samplesPerSecond: частота пиков waveform (по умолчанию 100/с, как `WaveformGenerator.generate`)
    ///   - windowSize: размер RMS-окна в сэмплах (по умолчанию 4096, как `SilenceSettings.windowSize`)
    ///   - progress: прогресс чтения файла (0...1)
    /// - Returns: `waveform` для таймлайна и `rms` — кеш для мгновенного пересчёта тишины
    public static func analyze(
        url: URL,
        samplesPerSecond: Int = 100,
        windowSize: Int = 4096,
        progress: ((Double) -> Void)? = nil
    ) async throws -> (waveform: WaveformData, rms: RMSCache) {
        let sampleRate = 44100
        let rawSamplesPerPeak = sampleRate / samplesPerSecond

        // Два независимых carry-буфера/индекса на общем потоке сэмплов — по образцу
        // WaveformGenerator.generate (пики) и SilenceDetector.detect (RMS-окна).
        var peakCarry: [Float] = []
        var peaks: [Float] = []

        var rmsCarry: [Float] = []
        var rmsValues: [Float] = []

        let sampleCount: Int
        do {
            let result = try await AudioSampleStream.read(from: url, sampleRate: sampleRate) { chunk, fraction in
                // Пики waveform (chunk = sampleRate / samplesPerSecond), как в WaveformGenerator.generate
                peakCarry.append(contentsOf: chunk)
                var peakStart = 0
                while peakCarry.count - peakStart >= rawSamplesPerPeak {
                    let peak = peakCarry.withUnsafeBufferPointer { buf -> Float in
                        var value: Float = 0
                        if let base = buf.baseAddress {
                            vDSP_maxmgv(base + peakStart, 1, &value, vDSP_Length(rawSamplesPerPeak))
                        }
                        return value
                    }
                    peaks.append(peak)
                    peakStart += rawSamplesPerPeak
                }
                if peakStart > 0 { peakCarry.removeFirst(peakStart) }

                // RMS-окна (windowSize), как в SilenceDetector.detect(in:)
                rmsCarry.append(contentsOf: chunk)
                var rmsStart = 0
                while rmsCarry.count - rmsStart >= windowSize {
                    let rms = rmsCarry.withUnsafeBufferPointer { buf -> Float in
                        var value: Float = 0
                        if let base = buf.baseAddress {
                            vDSP_rmsqv(base + rmsStart, 1, &value, vDSP_Length(windowSize))
                        }
                        return value
                    }
                    rmsValues.append(rms)
                    rmsStart += windowSize
                }
                if rmsStart > 0 { rmsCarry.removeFirst(rmsStart) }

                progress?(fraction)
            }
            sampleCount = result.sampleCount
        } catch let error as AudioSampleStream.StreamError {
            switch error {
            case .noAudioTrack: throw AnalysisError.noAudioTrack
            case .cannotRead: throw AnalysisError.cannotRead
            }
        }

        // Хвост пиков короче полного чанка — добираем как в WaveformGenerator.generate.
        if !peakCarry.isEmpty {
            let peak = peakCarry.withUnsafeBufferPointer { buf -> Float in
                var value: Float = 0
                if let base = buf.baseAddress {
                    vDSP_maxmgv(base, 1, &value, vDSP_Length(buf.count))
                }
                return value
            }
            peaks.append(peak)
        }
        // Хвост RMS короче windowSize сознательно НЕ добирается — как в SilenceDetector.detect(in:) —
        // чтобы rmsValues здесь были идентичны тем, что накопил бы внутренний цикл detect(in:).

        // Нормализация пиков 0-1 — как в WaveformGenerator.generate
        var maxVal: Float = 0
        vDSP_maxv(peaks, 1, &maxVal, vDSP_Length(peaks.count))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(peaks.count))
        }

        let totalDuration = Double(sampleCount) / Double(sampleRate)
        progress?(1.0)

        let waveform = WaveformData(peaks: peaks, duration: totalDuration, samplesPerSecond: samplesPerSecond)
        let rms = RMSCache(
            rmsValues: rmsValues,
            windowDuration: Double(windowSize) / Double(sampleRate),
            totalDuration: totalDuration
        )
        return (waveform, rms)
    }
}
