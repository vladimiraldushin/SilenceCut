import Foundation
import AVFoundation
import CoreMedia

/// Результат измерения громкости по ITU-R BS.1770-4 / EBU R128.
public struct LoudnessMeasurement: Sendable, Equatable {
    /// Интегрированная громкость (гейтинг по BS.1770-4), LUFS. −70 — тишина (гейтинг не оставил ни одного блока).
    public let integratedLUFS: Double
    /// Пиковый уровень сэмпла (до K-взвешивания) по всем каналам, dBFS.
    public let peakDBFS: Double
    public let channelCount: Int

    public init(integratedLUFS: Double, peakDBFS: Double, channelCount: Int) {
        self.integratedLUFS = integratedLUFS
        self.peakDBFS = peakDBFS
        self.channelCount = channelCount
    }
}

/// Измерение громкости по ITU-R BS.1770-4 / EBU R128 (интегрированная LUFS + пик) и расчёт
/// линейного гейна до целевой громкости (нормализация под соцсети, обычно −14 LUFS).
public enum LoudnessAnalyzer {

    public enum LoudnessError: Error {
        case noAudioTrack
        case cannotRead
    }

    /// Частота, к которой приводим исходник при чтении — коэффициенты K-фильтра ниже посчитаны именно для неё.
    private static let sampleRate = 48000.0

    /// Интегрированная громкость по BS.1770-4 + пик. Потоковое чтение через AVAssetReader —
    /// AudioSampleStream тут не годится (он mono 44.1 кГц, а для LUFS нужны все каналы и 48 кГц).
    /// Читает чанками (константная память): хранит не сэмплы, а по одному Double на каждые 100 мс.
    public static func measure(
        url: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws -> LoudnessMeasurement {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LoudnessError.noAudioTrack
        }
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))

        var sourceChannels = 1
        if let desc = try await audioTrack.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            sourceChannels = Int(asbd.pointee.mChannelsPerFrame)
        }
        let channelCount = max(1, min(sourceChannels, 2))

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LoudnessError.cannotRead
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw LoudnessError.cannotRead
        }

        var accumulator = LoudnessAccumulator(channelCount: channelCount, sampleRate: sampleRate)
        let expectedFrames = max(assetDuration * sampleRate, 1)
        var totalFrames = 0

        while let buffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            var interleaved = [Float](repeating: 0, count: floatCount)
            interleaved.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }

            let frameCount = floatCount / channelCount
            for i in 0..<frameCount {
                let offset = i * channelCount
                accumulator.addFrame { ch in interleaved[offset + ch] }
            }
            totalFrames += frameCount
            progress?(min(Double(totalFrames) / expectedFrames, 1.0))
        }

        if reader.status == .failed {
            throw LoudnessError.cannotRead
        }
        progress?(1.0)
        return accumulator.finalize()
    }

    /// Чистая функция измерения по готовым массивам сэмплов (по каналам, деинтерлив) — не читает файлы,
    /// поэтому тестируется на сигналах, сгенерированных кодом. `measure(url:)` копит те же данные через
    /// общий `LoudnessAccumulator`, только потоково по чанкам, а не за один вызов.
    static func measure(channels: [[Float]], sampleRate: Double) -> LoudnessMeasurement {
        let channelCount = max(1, channels.count)
        var accumulator = LoudnessAccumulator(channelCount: channelCount, sampleRate: sampleRate)
        let frameCount = channels.map(\.count).min() ?? 0
        for i in 0..<frameCount {
            accumulator.addFrame { ch in channels[ch][i] }
        }
        return accumulator.finalize()
    }

    /// Линейный множитель громкости до `targetLUFS` с защитой от клиппинга: гейн ограничивается так,
    /// чтобы пик не превысил `ceilingDBFS`. Для тишины (integratedLUFS ≤ −70) — гейн 1.0 (нормализовать нечего).
    public static func gain(
        for measurement: LoudnessMeasurement,
        targetLUFS: Double = -14,
        ceilingDBFS: Double = -1
    ) -> Double {
        guard measurement.integratedLUFS > -70 else { return 1.0 }
        let desiredDB = targetLUFS - measurement.integratedLUFS
        let maxDB = ceilingDBFS - measurement.peakDBFS
        let appliedDB = min(desiredDB, maxDB)
        let gain = pow(10.0, appliedDB / 20.0)
        return min(max(gain, 0.05), 8.0)
    }
}

// MARK: - K-взвешивание (BS.1770-4, коэффициенты для 48 кГц)

/// Каскад из двух биквадов (high-shelf + RLB high-pass). Состояние — на канал, продолжается между
/// чанками (не сбрасывается на границах буферов), иначе в измерении будут щелчки.
private struct KWeightingFilter {
    // Стадия 1: high-shelf
    private let b0_1 = 1.53512485958697
    private let b1_1 = -2.69169618940638
    private let b2_1 = 1.19839281085285
    private let a1_1 = -1.69065929318241
    private let a2_1 = 0.73248077421585
    private var x1_1: Double = 0, x2_1: Double = 0, y1_1: Double = 0, y2_1: Double = 0

    // Стадия 2: RLB high-pass
    private let b0_2 = 1.0
    private let b1_2 = -2.0
    private let b2_2 = 1.0
    private let a1_2 = -1.99004745483398
    private let a2_2 = 0.99007225036621
    private var x1_2: Double = 0, x2_2: Double = 0, y1_2: Double = 0, y2_2: Double = 0

    /// y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] − a1*y[n-1] − a2*y[n-2], каскадом через обе стадии.
    mutating func process(_ sample: Float) -> Double {
        let x = Double(sample)
        let y1 = b0_1 * x + b1_1 * x1_1 + b2_1 * x2_1 - a1_1 * y1_1 - a2_1 * y2_1
        x2_1 = x1_1; x1_1 = x
        y2_1 = y1_1; y1_1 = y1

        let y2 = b0_2 * y1 + b1_2 * x1_2 + b2_2 * x2_2 - a1_2 * y1_2 - a2_2 * y2_2
        x2_2 = x1_2; x1_2 = y1
        y2_2 = y1_2; y1_2 = y2

        return y2
    }
}

// MARK: - Накопление под-блоков и гейтинг

/// Общая логика для потокового `measure(url:)` и чистой `measure(channels:sampleRate:)`: K-взвешивание
/// каждого сэмпла, накопление суммы квадратов по под-блокам 100 мс (по каналам) и пик до фильтра.
/// Ничего длиннее одного под-блока не хранит — блоки 400 мс и гейтинг считаются в `finalize()`
/// по готовым под-блочным суммам (для часового ролика это ~36000 Double на канал, не сэмплы).
private struct LoudnessAccumulator {
    private var filters: [KWeightingFilter]
    private let channelCount: Int
    private let subBlockSize: Int
    private var subBlockSumSquares: [Double]
    private var subBlockFrameCount = 0
    private var subBlockMeanSquares: [[Double]]   // [канал][индекс под-блока]
    private var peak: Float = 0

    init(channelCount: Int, sampleRate: Double) {
        self.channelCount = channelCount
        filters = Array(repeating: KWeightingFilter(), count: channelCount)
        subBlockSize = max(1, Int((sampleRate * 0.1).rounded()))
        subBlockSumSquares = Array(repeating: 0, count: channelCount)
        subBlockMeanSquares = Array(repeating: [], count: channelCount)
    }

    /// Один фрейм по всем каналам; `sample(ch)` отдаёт сэмпл канала `ch` — не важно, из interleaved-буфера
    /// (`measure(url:)`) или из отдельных массивов (`measure(channels:)`), накопитель работает одинаково.
    mutating func addFrame(_ sample: (Int) -> Float) {
        for ch in 0..<channelCount {
            let raw = sample(ch)
            let magnitude = abs(raw)
            if magnitude > peak { peak = magnitude }
            let filtered = filters[ch].process(raw)
            subBlockSumSquares[ch] += filtered * filtered
        }
        subBlockFrameCount += 1
        if subBlockFrameCount == subBlockSize {
            for ch in 0..<channelCount {
                subBlockMeanSquares[ch].append(subBlockSumSquares[ch] / Double(subBlockSize))
                subBlockSumSquares[ch] = 0
            }
            subBlockFrameCount = 0
        }
        // Хвост короче под-блока сознательно не добираем (как RMS-окна в SilenceDetector) —
        // на 100 мс шаге для часового ролика это меньше 0.003% сигнала.
    }

    func finalize() -> LoudnessMeasurement {
        let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -120.0
        let subBlockCount = subBlockMeanSquares.first?.count ?? 0

        // Блоки 400 мс = 4 под-блока по 100 мс внахлёст с шагом в 1 под-блок (перекрытие 75%).
        var blocks: [(loudness: Double, z: Double)] = []
        if subBlockCount >= 4 {
            for j in 0...(subBlockCount - 4) {
                var z = 0.0
                for ch in 0..<channelCount {
                    // G_ch = 1.0 для моно/L/R (единственные каналы, которые сюда доходят)
                    z += (subBlockMeanSquares[ch][j] + subBlockMeanSquares[ch][j + 1]
                        + subBlockMeanSquares[ch][j + 2] + subBlockMeanSquares[ch][j + 3]) / 4
                }
                blocks.append((loudness: -0.691 + 10 * log10(z), z: z))
            }
        }

        // Абсолютный гейт: −70 LUFS.
        let absGated = blocks.filter { $0.loudness > -70 }
        guard !absGated.isEmpty else {
            return LoudnessMeasurement(integratedLUFS: -70, peakDBFS: peakDB, channelCount: channelCount)
        }

        // Относительный гейт: Γ = громкость по блокам, прошедшим абсолютный гейт, минус 10 дБ.
        let meanAbsZ = absGated.reduce(0.0) { $0 + $1.z } / Double(absGated.count)
        let relativeThreshold = -0.691 + 10 * log10(meanAbsZ) - 10

        let bothGated = absGated.filter { $0.loudness > relativeThreshold }
        guard !bothGated.isEmpty else {
            return LoudnessMeasurement(integratedLUFS: -70, peakDBFS: peakDB, channelCount: channelCount)
        }
        let meanBothZ = bothGated.reduce(0.0) { $0 + $1.z } / Double(bothGated.count)
        let integrated = -0.691 + 10 * log10(meanBothZ)

        return LoudnessMeasurement(integratedLUFS: integrated, peakDBFS: peakDB, channelCount: channelCount)
    }
}
