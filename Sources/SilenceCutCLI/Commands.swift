import Foundation
import CoreMedia

/// Команды CLI. Все читающие команды печатают JSON: инструментом пользуется языковая
/// модель, и разбирать таблицы для человека ей незачем.
enum Commands {

    // MARK: - Чтение

    static func info(_ args: Arguments) throws {
        let url = try args.projectURL()
        let snapshot = try load(url)
        let timeline = snapshot.timeline

        printJSON([
            "project": url.path,
            "name": snapshot.name,
            "version": snapshot.version,
            "savedAt": ISO8601DateFormatter().string(from: snapshot.savedAt),
            "durationSeconds": round(CMTimeGetSeconds(timeline.duration) * 1000) / 1000,
            "frameRate": timeline.sources.first?.nominalFrameRate ?? 30,
            "canvas": canvasDescription(timeline),
            "counts": [
                "sources": timeline.sources.count,
                "clips": timeline.clips.count,
                "overlays": timeline.overlays.count,
                "graphics": timeline.graphics.count,
                "subtitles": snapshot.subtitleEntries.count,
            ],
        ])
    }

    static func list(_ args: Arguments) throws {
        let url = try args.projectURL()
        let timeline = try load(url).timeline

        var payload: [String: Any] = [:]
        let wantsAll = !args.has("sources") && !args.has("clips")
            && !args.has("overlays") && !args.has("graphics")

        if wantsAll || args.has("sources") {
            payload["sources"] = timeline.sources.map { source in
                [
                    "id": source.id.uuidString,
                    "name": source.displayName,
                    "path": source.url.path,
                    "durationSeconds": round(CMTimeGetSeconds(source.duration) * 1000) / 1000,
                    "width": Int(source.naturalSize.width),
                    "height": Int(source.naturalSize.height),
                    "hasAudio": source.hasAudio,
                    "exists": FileManager.default.fileExists(atPath: source.url.path),
                ] as [String: Any]
            }
        }
        if wantsAll || args.has("clips") {
            payload["clips"] = timeline.clips.map { clip in
                [
                    "id": clip.id.uuidString,
                    "sourceID": clip.sourceID.uuidString,
                    "timelineStart": seconds(clip.timelineOffset),
                    "durationSeconds": seconds(clip.effectiveDuration),
                    "isEnabled": clip.isEnabled,
                ] as [String: Any]
            }
        }
        if wantsAll || args.has("overlays") {
            payload["overlays"] = timeline.overlays.map { overlay in
                [
                    "id": overlay.id.uuidString,
                    "sourceID": overlay.sourceID.uuidString,
                    "timelineStart": seconds(overlay.timelineStart),
                    "durationSeconds": seconds(overlay.sourceRange.duration),
                    "isEnabled": overlay.isEnabled,
                ] as [String: Any]
            }
        }
        if wantsAll || args.has("graphics") {
            payload["graphics"] = timeline.graphics.map { graphic in
                var item: [String: Any] = [
                    "id": graphic.id.uuidString,
                    "sourceID": graphic.sourceID.uuidString,
                    "timelineStart": seconds(graphic.timelineStart),
                    "durationSeconds": seconds(graphic.sourceRange.duration),
                    "isEnabled": graphic.isEnabled,
                ]
                if let origin = graphic.origin {
                    item["template"] = origin.template
                    item["props"] = origin.propsJSON
                    item["packVersion"] = origin.packVersion as Any
                }
                return item
            }
        }
        printJSON(payload)
    }

    /// Что нужно знать рендереру титров, чтобы попасть в проект
    static func canvas(_ args: Arguments) throws {
        let timeline = try load(try args.projectURL()).timeline
        printJSON(canvasDescription(timeline))
    }

    // MARK: - Создание

    /// Новый проект с одним роликом на всю длину. Нужен конвейеру: собрать монтаж и
    /// положить в него титры можно без запуска приложения.
    static func new(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        guard !FileManager.default.fileExists(atPath: projectURL.path) || args.has("force") else {
            throw CLIError.invalid("Файл уже существует: \(projectURL.path). Перезаписать — --force")
        }

        let videoPath = try args.requireString("video")
        let videoURL = URL(fileURLWithPath: (videoPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw CLIError.notFound(videoURL.path)
        }

        let source = try await MediaSource.load(from: videoURL)
        let full = CMTimeRange(start: .zero, duration: source.duration)
        let timeline = EditTimeline(
            sources: [source],
            clips: [TimelineClip(sourceID: source.id, availableRange: full, sourceRange: full)]
        )

        let snapshot = ProjectSnapshot(
            name: args.string("name") ?? projectURL.deletingPathExtension().lastPathComponent,
            timeline: timeline,
            subtitleEntries: [],
            subtitleStyle: .classic,
            renderOptions: .default
        )
        try ProjectStore.save(snapshot, to: projectURL)

        printJSON([
            "created": projectURL.path,
            "name": snapshot.name,
            "durationSeconds": seconds(source.duration),
            "canvas": canvasDescription(timeline),
        ])
    }

    // MARK: - Правка

    static func addGraphic(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try load(projectURL)

        let filePath = try args.requireString("file")
        let fileURL = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.notFound(fileURL.path)
        }

        let at = try args.requireDouble("at")
        let source = try await resolveSource(fileURL, in: &snapshot.timeline)

        // По умолчанию берём титр целиком
        let full = CMTimeGetSeconds(source.duration)
        let duration = min(args.double("duration") ?? full, full)
        guard duration > 0.001 else {
            throw CLIError.invalid("Длительность титра нулевая: \(fileURL.lastPathComponent)")
        }

        var origin: GraphicOrigin?
        if let template = args.string("template") {
            origin = GraphicOrigin(
                template: template,
                propsJSON: args.string("props") ?? "{}",
                packVersion: args.string("pack-version")
            )
        }

        let graphic = GraphicClip(
            sourceID: source.id,
            sourceRange: CMTimeRange(
                start: CMTime(seconds: args.double("source-start") ?? 0, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            ),
            timelineStart: CMTime(seconds: max(0, at), preferredTimescale: 600),
            origin: origin
        )
        snapshot.timeline.graphics.append(graphic)

        try save(snapshot, to: projectURL)
        printJSON([
            "added": "graphic",
            "id": graphic.id.uuidString,
            "timelineStart": seconds(graphic.timelineStart),
            "durationSeconds": seconds(graphic.sourceRange.duration),
            "warning": warningIfPastEnd(graphic, timeline: snapshot.timeline) as Any,
        ])
    }

    static func moveGraphic(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try load(projectURL)

        let id = try uuid(args.requireString("id"))
        guard let index = snapshot.timeline.graphics.firstIndex(where: { $0.id == id }) else {
            throw CLIError.notFound("титр \(id.uuidString)")
        }
        let at = try args.requireDouble("at")
        snapshot.timeline.graphics[index].timelineStart =
            CMTime(seconds: max(0, at), preferredTimescale: 600)

        try save(snapshot, to: projectURL)
        printJSON(["moved": id.uuidString, "timelineStart": max(0, at)])
    }

    static func removeGraphic(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try load(projectURL)

        let id = try uuid(args.requireString("id"))
        let before = snapshot.timeline.graphics.count
        snapshot.timeline.graphics.removeAll { $0.id == id }
        guard snapshot.timeline.graphics.count < before else {
            throw CLIError.notFound("титр \(id.uuidString)")
        }

        try save(snapshot, to: projectURL)
        printJSON(["removed": id.uuidString])
    }

    // MARK: - Проверка

    static func validate(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        let timeline = try load(projectURL).timeline
        var problems: [[String: Any]] = []

        let knownIDs = Set(timeline.sources.map(\.id))
        for source in timeline.sources where !FileManager.default.fileExists(atPath: source.url.path) {
            problems.append(["kind": "missing-file", "source": source.url.path])
        }
        for clip in timeline.clips where !knownIDs.contains(clip.sourceID) {
            problems.append(["kind": "orphan-clip", "id": clip.id.uuidString])
        }
        for overlay in timeline.overlays where !knownIDs.contains(overlay.sourceID) {
            problems.append(["kind": "orphan-overlay", "id": overlay.id.uuidString])
        }
        for graphic in timeline.graphics {
            if !knownIDs.contains(graphic.sourceID) {
                problems.append(["kind": "orphan-graphic", "id": graphic.id.uuidString])
            }
            if let warning = warningIfPastEnd(graphic, timeline: timeline) {
                problems.append([
                    "kind": "graphic-past-end", "id": graphic.id.uuidString, "detail": warning,
                ])
            }
        }

        // Слой один, поэтому наехавший клип при сборке композиции просто пропускается.
        // Молча теряющийся титр — худший из возможных исходов, ловим заранее.
        problems += overlaps(in: timeline.graphics, kind: "graphic-overlap")
        problems += overlaps(in: timeline.overlays, kind: "overlay-overlap")

        printJSON(["ok": problems.isEmpty, "problems": problems])
        if !problems.isEmpty { exit(1) }
    }

    // MARK: - Вспомогательное

    private static func load(_ url: URL) throws -> ProjectSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound(url.path)
        }
        return try ProjectStore.load(from: url)
    }

    private static func save(_ snapshot: ProjectSnapshot, to url: URL) throws {
        var updated = snapshot
        updated.savedAt = Date()
        try ProjectStore.save(updated, to: url)
    }

    /// Файл уже в реестре — переиспользуем запись, иначе заводим новую.
    /// Один и тот же титр, вставленный дважды, не должен плодить источники.
    private static func resolveSource(
        _ url: URL, in timeline: inout EditTimeline
    ) async throws -> MediaSource {
        let standardized = url.standardizedFileURL.path
        if let existing = timeline.sources.first(where: { $0.url.standardizedFileURL.path == standardized }) {
            return existing
        }
        let source = try await MediaSource.load(from: url)
        timeline.sources.append(source)
        return source
    }

    private static func canvasDescription(_ timeline: EditTimeline) -> [String: Any] {
        let size = timeline.sources.first?.orientedSize ?? .zero
        return [
            "width": Int(size.width),
            "height": Int(size.height),
            "frameRate": timeline.sources.first?.nominalFrameRate ?? 30,
            "durationSeconds": round(CMTimeGetSeconds(timeline.duration) * 1000) / 1000,
        ]
    }

    /// Пары клипов одного слоя, налезающих друг на друга по времени
    private static func overlaps<Clip: PinnedClip>(
        in clips: [Clip], kind: String
    ) -> [[String: Any]] {
        let sorted = clips
            .filter(\.isEnabled)
            .sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        var found: [[String: Any]] = []
        for (index, clip) in sorted.enumerated() where index + 1 < sorted.count {
            let end = CMTimeGetSeconds(clip.timelineStart) + CMTimeGetSeconds(clip.sourceRange.duration)
            let next = sorted[index + 1]
            let nextStart = CMTimeGetSeconds(next.timelineStart)
            guard nextStart < end - 0.001 else { continue }
            found.append([
                "kind": kind,
                "id": "\(next.id)",
                "detail": "накладывается на предыдущий до \(fmt(end)) с и не попадёт в кадр",
            ])
        }
        return found
    }

    private static func warningIfPastEnd(_ graphic: GraphicClip, timeline: EditTimeline) -> String? {
        let end = CMTimeGetSeconds(timeline.duration)
        let start = CMTimeGetSeconds(graphic.timelineStart)
        if start >= end {
            return "начинается за концом монтажа (\(fmt(end)) с) и не попадёт в кадр"
        }
        if start + CMTimeGetSeconds(graphic.sourceRange.duration) > end + 0.001 {
            return "выходит за конец монтажа и будет подрезан"
        }
        return nil
    }

    private static func uuid(_ raw: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else {
            throw CLIError.invalid("Не похоже на идентификатор: \(raw)")
        }
        return value
    }

    private static func seconds(_ time: CMTime) -> Double {
        round(CMTimeGetSeconds(time) * 1000) / 1000
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
