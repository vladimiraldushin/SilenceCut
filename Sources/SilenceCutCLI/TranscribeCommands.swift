import Foundation
import CoreMedia
import RECore
import REExport
import REAudioAnalysis

/// Транскрибация смонтированного звука.
///
/// По умолчанию НИЧЕГО не пишет в проект — только отдаёт текст. Это главное свойство
/// команды: расшифровка нужна прежде всего для понимания, что происходит в ролике, а
/// подписи в кадре — отдельное решение, которое принимает человек. Записать в проект
/// можно явным `--apply`.
///
/// Разбирается именно СМОНТИРОВАННЫЙ звук, а не исходники: тайминги должны совпадать со
/// временем таймлайна, иначе по ним нельзя ни ставить титры, ни искать место в монтаже.
enum TranscribeCommands {

    static func transcribe(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        guard snapshot.timeline.enabledClipCount > 0 else {
            throw CLIError.invalid("В проекте нет включённых клипов")
        }
        let missing = snapshot.timeline.sources.filter {
            !FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard missing.isEmpty else {
            throw CLIError.invalid(
                "Не найдены исходники: \(missing.map(\.displayName).joined(separator: ", "))"
            )
        }

        // Звук таймлайна во временный файл: кодировать видео ради расшифровки незачем
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silencecut_cli_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        FileHandle.standardError.write(Data("Сборка звука таймлайна...\n".utf8))
        try await ExportService.exportAudioOnly(timeline: snapshot.timeline, to: tempURL)

        // По умолчанию берётся модель, выбранная в приложении (обычно parakeet-v3):
        // расшифровка из CLI не должна отличаться от той, что делает редактор
        let manager = await ModelManager()
        if let model = args.string("model") {
            await MainActor.run { manager.selectedModelId = model }
        }
        if let language = args.string("language") {
            await MainActor.run { manager.selectedLanguage = language }
        }
        let modelName = await MainActor.run { manager.selectedModelId }

        FileHandle.standardError.write(Data("Транскрибация (\(modelName))...\n".utf8))
        var lastPhase = ""
        let entries = try await TranscriptionService.transcribe(
            url: tempURL, modelManager: manager
        ) { progress in
            // Прогресс в stderr: stdout обязан остаться разбираемым JSON
            let phase = progress.phase.rawValue
            if phase != lastPhase {
                lastPhase = phase
                FileHandle.standardError.write(Data("  \(phase)\n".utf8))
            }
        }

        if args.has("apply") {
            snapshot.subtitleEntries = entries
            try Shared.save(snapshot, to: projectURL)
        }

        if let srtPath = args.string("srt") {
            let url = URL(fileURLWithPath: (srtPath as NSString).expandingTildeInPath)
            try Data(srt(from: entries).utf8).write(to: url, options: .atomic)
            FileHandle.standardError.write(Data("SRT: \(url.path)\n".utf8))
        }

        // Сплошной текст удобнее для чтения, посегментный — для работы со временем
        Shared.printJSON([
            "applied": args.has("apply"),
            "model": modelName,
            "segments": entries.count,
            "durationSeconds": Shared.seconds(snapshot.timeline.duration),
            "text": entries.map(\.text).joined(separator: " "),
            "lines": entries.map { entry in
                [
                    "start": Shared.seconds(entry.startTime),
                    "end": Shared.seconds(entry.endTime),
                    "text": entry.text,
                ] as [String: Any]
            },
        ])
    }

    private static func srt(from entries: [SubtitleEntry]) -> String {
        entries.enumerated().map { index, entry in
            "\(index + 1)\n\(stamp(entry.startTime)) --> \(stamp(entry.endTime))\n\(entry.text)\n"
        }.joined(separator: "\n")
    }

    private static func stamp(_ time: CMTime) -> String {
        let total = max(0, CMTimeGetSeconds(time))
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
