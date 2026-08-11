import Foundation
import AVFoundation
import CoreMedia
import RECore
import REAudioAnalysis

/// Выравнивание громкости по клипам.
///
/// Микрофон пропадает не на весь дубль, а на отдельные реплики: в одном файле часть
/// кусков записана нормально, часть — на 15 дБ тише. Гейн на источник тут бессилен,
/// поэтому громкость правится по клипам.
///
/// Подъём ограничен запасом до пика. Клип, у которого пик уже близко к нулю, поднять
/// на нужные децибелы нельзя — получится клиппинг, то есть хрип вместо громкости.
/// Такие клипы поднимаются насколько можно и отмечаются в отчёте.
///
/// Клипы без речи не трогаются вовсе. Подтянуть фон или паузу — значит поднять один
/// только шум: в кадре ничего не станет слышнее, зато появится шипение. Речь отличается
/// от фона не уровнем, а РАЗМАХОМ: слоги чередуются с промежутками, и короткие окна
/// громкости разбегаются на десяток децибел. У ровного фона они стоят на месте.
enum LevelCommands {

    static func levelAudio(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        let missing = snapshot.timeline.sources.filter {
            !FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard missing.isEmpty else {
            throw CLIError.invalid(
                "Не найдены исходники: \(missing.map(\.displayName).joined(separator: ", "))"
            )
        }

        // Запас до нуля: на 1 дБ ниже потолка цифра ещё не искажается
        let headroom = args.double("headroom") ?? 1.0
        let maxBoost = args.double("max-boost") ?? 18.0

        // Порог размаха: у речи разброс коротких окон обычно больше 9 дБ,
        // у комнатного тона и улицы — редко больше 5
        let speechSpread = args.double("speech-spread") ?? 8.0
        var measured: [(index: Int, mean: Double, peak: Double, spread: Double)] = []

        for (index, clip) in snapshot.timeline.clips.enumerated() {
            guard clip.isEnabled,
                  let source = snapshot.timeline.source(for: clip.sourceID),
                  source.hasAudio else { continue }
            guard let m = try await measure(
                url: source.url,
                start: CMTimeGetSeconds(clip.sourceRange.start),
                duration: CMTimeGetSeconds(clip.sourceRange.duration)
            ) else { continue }
            measured.append((index, m.mean, m.peak, m.spread))
        }

        guard !measured.isEmpty else {
            throw CLIError.invalid("Не удалось измерить ни одного клипа")
        }

        // Цель — медиана по ролику, а не абсолютный уровень: так выравнивание не
        // перекраивает общую громкость монтажа, а только подтягивает выпавшие куски
        let sortedMeans = measured.map(\.mean).sorted()
        let target = args.double("target") ?? sortedMeans[sortedMeans.count / 2]

        var report: [[String: Any]] = []
        var raised = 0

        for item in measured {
            let needed = target - item.mean
            // Опускать громкие клипы не будем: чаще всего это не брак, а эмоция
            guard needed > 1.0 else { continue }

            guard item.spread >= speechSpread else {
                report.append([
                    "clip": snapshot.timeline.clips[item.index].id.uuidString,
                    "timelineStart": Shared.seconds(snapshot.timeline.clips[item.index].timelineOffset),
                    "meanDb": Shared.round3(item.mean),
                    "spreadDb": Shared.round3(item.spread),
                    "skipped": "нет речи — только фон",
                ])
                continue
            }

            let allowed = min(needed, min(maxBoost, -item.peak - headroom))
            guard allowed > 0.5 else {
                report.append([
                    "clip": snapshot.timeline.clips[item.index].id.uuidString,
                    "timelineStart": Shared.seconds(snapshot.timeline.clips[item.index].timelineOffset),
                    "meanDb": Shared.round3(item.mean),
                    "peakDb": Shared.round3(item.peak),
                    "spreadDb": Shared.round3(item.spread),
                    "skipped": "нет запаса до пика",
                ])
                continue
            }

            let factor = pow(10.0, allowed / 20.0)
            if args.has("apply") {
                snapshot.timeline.clips[item.index].gain = factor
            }
            raised += 1
            report.append([
                "clip": snapshot.timeline.clips[item.index].id.uuidString,
                "timelineStart": Shared.seconds(snapshot.timeline.clips[item.index].timelineOffset),
                "meanDb": Shared.round3(item.mean),
                "peakDb": Shared.round3(item.peak),
                "boostDb": Shared.round3(allowed),
                "spreadDb": Shared.round3(item.spread),
                "clipped": allowed < needed - 0.5 ? "поднято не полностью — упёрлось в пик" : nil,
            ].compactMapValues { $0 })
        }

        if args.has("apply") {
            try Shared.save(snapshot, to: projectURL)
        }

        Shared.printJSON([
            "applied": args.has("apply"),
            "targetDb": Shared.round3(target),
            "measuredClips": measured.count,
            "raisedClips": raised,
            "clips": report,
            "hint": args.has("apply") ? nil : "добавьте --apply, чтобы записать в проект",
        ].compactMapValues { $0 })
    }

    /// Средняя и пиковая громкость куска в децибелах.
    ///
    /// Считается по сэмплам через AVAssetReader, а не внешним инструментом: CLI должен
    /// работать там, где ffmpeg не установлен.
    private static func measure(
        url: URL, start: Double, duration: Double
    ) async throws -> (mean: Double, peak: Double, spread: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return nil }

        var sumSquares = 0.0
        var count = 0
        var peak: Float = 0

        // Короткие окна для размаха: 1024 сэмпла это примерно 23 мс при 44,1 кГц —
        // слог целиком туда не влезает, зато провал между слогами виден
        var windowSum = 0.0
        var windowCount = 0
        var windowRms: [Double] = []

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }

            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for i in 0..<(length / 4) {
                    let v = samples[i]
                    let square = Double(v * v)
                    sumSquares += square
                    peak = max(peak, abs(v))
                    count += 1

                    windowSum += square
                    windowCount += 1
                    if windowCount == 1024 {
                        windowRms.append((windowSum / 1024).squareRoot())
                        windowSum = 0
                        windowCount = 0
                    }
                }
            }
        }
        guard count > 0 else { return nil }

        let rms = (sumSquares / Double(count)).squareRoot()
        let meanDb = 20 * log10(max(rms, 1e-7))
        let peakDb = 20 * log10(max(Double(peak), 1e-7))

        // Размах между громкими и тихими окнами. Крайние проценты отброшены: одиночный
        // щелчок или мгновенная пауза не должны выдавать себя за речь.
        var spread = 0.0
        if windowRms.count > 8 {
            let sorted = windowRms.sorted()
            let loud = sorted[Int(Double(sorted.count) * 0.9)]
            let quiet = sorted[Int(Double(sorted.count) * 0.2)]
            spread = 20 * log10(max(loud, 1e-7) / max(quiet, 1e-7))
        }
        return (meanDb, peakDb, spread)
    }
}
