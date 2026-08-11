import Foundation
import AVFoundation
import CoreMedia
import RECore
import RETimeline
import REExport
import REAudioAnalysis

/// Экспорт и детекция пауз из командной строки.
///
/// Вместе с командами монтажа это даёт полностью безголовый конвейер: собрать проект,
/// вырезать паузы, положить заставку и титры, отдать готовый файл — не открывая приложение.
enum RenderCommands {

    // MARK: - Экспорт

    static func export(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        let snapshot = try Shared.load(projectURL)

        let outPath = try args.requireString("out")
        let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: outURL.path) {
            guard args.has("force") else {
                throw CLIError.invalid("Файл уже существует: \(outURL.path). Перезаписать — --force")
            }
            try? FileManager.default.removeItem(at: outURL)
        }

        // Офлайн-источник даст пустой кадр вместо картинки — лучше остановиться сразу
        let missing = snapshot.timeline.sources.filter {
            !FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard missing.isEmpty else {
            throw CLIError.invalid(
                "Не найдены исходники: \(missing.map(\.displayName).joined(separator: ", "))"
            )
        }
        guard snapshot.timeline.enabledClipCount > 0 else {
            throw CLIError.invalid("В проекте нет включённых клипов")
        }

        let preset: ExportPreset
        switch args.string("preset") ?? "high" {
        case "low": preset = .low
        case "medium": preset = .medium
        default: preset = .high
        }

        let burnSubtitles = args.has("subtitles") && !snapshot.subtitleEntries.isEmpty
        var options = snapshot.renderOptions ?? .default
        if let aspect = args.string("aspect"), let parsed = OutputAspect(cliName: aspect) {
            options.outputAspect = parsed
        }

        FileHandle.standardError.write(Data(
            "Экспорт \(Shared.seconds(snapshot.timeline.duration)) с → \(outURL.lastPathComponent)\n".utf8
        ))

        var lastReported = -1
        try await ExportService.export(
            timeline: snapshot.timeline,
            to: outURL,
            preset: preset,
            subtitleEntries: burnSubtitles ? snapshot.subtitleEntries : [],
            subtitleStyle: snapshot.subtitleStyle,
            renderOptions: options
        ) { progress in
            // Прогресс в stderr: stdout должен остаться разбираемым JSON
            let percent = Int(progress.fraction * 100)
            if percent / 10 != lastReported / 10 {
                lastReported = percent
                FileHandle.standardError.write(Data("  \(percent)%\n".utf8))
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Shared.printJSON([
            "exported": outURL.path,
            "durationSeconds": Shared.seconds(snapshot.timeline.duration),
            "bytes": size ?? 0,
            "subtitlesBurned": burnSubtitles,
            "preset": args.string("preset") ?? "high",
        ])
    }

    // MARK: - Детекция пауз

    /// Находит паузы по каждому клипу хребта. Без `--apply` только показывает,
    /// сколько и где — резать вслепую по чужим порогам опаснее, чем посмотреть.
    static func detectSilence(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        var settings = SilenceSettings.normal
        if let threshold = args.double("threshold") { settings.thresholdDB = Float(threshold) }
        if let minimum = args.double("min-duration") { settings.minSilenceDuration = minimum }
        if let padding = args.double("padding") { settings.padding = padding }

        var report: [[String: Any]] = []
        var totalRemoved = 0.0

        // Идём с конца: вырез в раннем клипе сдвинул бы позиции поздних
        for clip in snapshot.timeline.clips.reversed() {
            guard clip.isEnabled,
                  let source = snapshot.timeline.source(for: clip.sourceID) else { continue }

            // Заставка и прочие немые вставки: пауз в них нет по определению,
            // а падать из-за них всей командой — значит не дать вырезать остальное
            guard source.hasAudio else {
                report.append([
                    "clip": clip.id.uuidString,
                    "source": source.displayName,
                    "skipped": "нет звуковой дорожки",
                ])
                continue
            }

            let analysis: (waveform: WaveformData, rms: RMSCache)
            do {
                analysis = try await AudioAnalysis.analyze(url: source.url)
            } catch {
                report.append([
                    "clip": clip.id.uuidString,
                    "source": source.displayName,
                    "skipped": "звук не прочитался: \(error.localizedDescription)",
                ])
                continue
            }
            let result = SilenceDetector.detect(cache: analysis.rms, settings: settings)

            // Паузы приходят в координатах исходника — оставляем только попавшие в клип
            let clipStart = CMTimeGetSeconds(clip.sourceRange.start)
            let clipEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange))
            let inClip = result.speechRanges.compactMap { range -> CMTimeRange? in
                let start = max(CMTimeGetSeconds(range.start), clipStart)
                let end = min(CMTimeGetSeconds(CMTimeRangeGetEnd(range)), clipEnd)
                guard end - start > 0.05 else { return nil }
                return CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: end - start, preferredTimescale: 600)
                )
            }

            let speech = inClip.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
            let removed = (clipEnd - clipStart) - speech
            totalRemoved += max(0, removed)

            report.append([
                "clip": clip.id.uuidString,
                "source": source.displayName,
                "speechRanges": inClip.count,
                "removesSeconds": Shared.round3(max(0, removed)),
            ])

            if args.has("apply"), !inClip.isEmpty, removed > 0.05 {
                let before = snapshot.timeline.duration
                snapshot.timeline.splitClipBySpeechRanges(clipID: clip.id, speechRanges: inClip)
                let cut = CMTimeSubtract(before, snapshot.timeline.duration)
                snapshot.subtitleEntries = SubtitleRipple.applyRemovals(
                    to: snapshot.subtitleEntries,
                    [CMTimeRange(start: clip.timelineOffset, duration: cut)]
                )
            }
        }

        if args.has("apply") {
            try Shared.save(snapshot, to: projectURL)
        }

        Shared.printJSON([
            "applied": args.has("apply"),
            "removesSeconds": Shared.round3(totalRemoved),
            "durationAfter": Shared.seconds(snapshot.timeline.duration),
            "perClip": Array(report.reversed()),
            "hint": args.has("apply") ? nil : "добавьте --apply, чтобы вырезать",
        ].compactMapValues { $0 })
    }
}

private extension OutputAspect {
    /// Разбор `--aspect 9:16` и синонимов
    init?(cliName: String) {
        switch cliName.lowercased() {
        case "9:16", "vertical", "reels": self = .vertical
        case "1:1", "square": self = .square
        case "16:9", "horizontal", "wide": self = .horizontal
        case "source", "original", "исходный": self = .source
        default: return nil
        }
    }
}
