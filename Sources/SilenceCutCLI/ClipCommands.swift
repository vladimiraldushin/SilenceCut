import Foundation
import CoreMedia
import RECore

/// Команды монтажа: клипы хребта, перебивки, источники.
///
/// Всё, что меняет длину таймлайна, обязано идти через операции `EditTimeline` и
/// применять возвращённый `TimelineEdit` к субтитрам. Прямая правка массивов оставила бы
/// титры и подписи на старых секундах — ровно та ошибка, ради которой в модели заведён
/// единый путь укорачивания.
enum ClipCommands {

    // MARK: - Хребет

    /// Вставка ролика в хребет: заставка (`--at 0`), отбивка, второй дубль.
    static func addClip(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        let fileURL = try Shared.fileArgument(args, key: "file")
        let source = try await Shared.resolveSource(fileURL, in: &snapshot.timeline)

        let full = CMTimeGetSeconds(source.duration)
        let duration = min(args.double("duration") ?? full, full)
        let sourceStart = max(0, args.double("source-start") ?? 0)
        guard duration > 0.001 else {
            throw CLIError.invalid("Длительность клипа нулевая: \(fileURL.lastPathComponent)")
        }

        let clip = TimelineClip(
            sourceID: source.id,
            availableRange: CMTimeRange(start: .zero, duration: source.duration),
            sourceRange: CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
        )

        // Без --at кладём в конец: так добавляют следующий дубль
        let at = args.double("at") ?? CMTimeGetSeconds(snapshot.timeline.duration)
        let edit = snapshot.timeline.insertClip(clip, at: CMTime(seconds: at, preferredTimescale: 600))
        snapshot.subtitleEntries = edit.apply(to: snapshot.subtitleEntries)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON([
            "added": "clip",
            "id": clip.id.uuidString,
            "timelineStart": Shared.round3(at),
            "durationSeconds": Shared.round3(duration),
            "timelineDuration": Shared.seconds(snapshot.timeline.duration),
            "subtitlesShifted": snapshot.subtitleEntries.count,
        ])
    }

    static func removeClip(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard snapshot.timeline.clips.contains(where: { $0.id == id }) else {
            throw CLIError.notFound("клип \(id.uuidString)")
        }
        let edit = snapshot.timeline.deleteClip(id: id)
        snapshot.subtitleEntries = edit.apply(to: snapshot.subtitleEntries)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON([
            "removed": id.uuidString,
            "timelineDuration": Shared.seconds(snapshot.timeline.duration),
        ])
    }

    /// Перестановка клипа к стыку. Номера стыков видно в `list --clips`.
    static func moveClip(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard snapshot.timeline.clips.contains(where: { $0.id == id }) else {
            throw CLIError.notFound("клип \(id.uuidString)")
        }
        let boundary = Int(try args.requireDouble("to-boundary"))
        snapshot.timeline.moveClip(id: id, toBoundary: boundary)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON(["moved": id.uuidString, "toBoundary": boundary])
    }

    static func splitClip(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        let at = try args.requireDouble("at")
        let time = CMTime(seconds: at, preferredTimescale: 600)
        guard let index = snapshot.timeline.clipIndex(at: time) else {
            throw CLIError.invalid("На \(at) с нет клипа — таймлайн длится \(Shared.seconds(snapshot.timeline.duration)) с")
        }
        // Разрез не меняет длину таймлайна, поэтому субтитры и титры не трогаем
        snapshot.timeline.splitClip(at: index, splitTime: time)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON(["split": Shared.round3(at), "clips": snapshot.timeline.clips.count])
    }

    static func toggleClip(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard let clip = snapshot.timeline.clips.first(where: { $0.id == id }) else {
            throw CLIError.notFound("клип \(id.uuidString)")
        }
        let edit = snapshot.timeline.toggleClip(id: id)
        snapshot.subtitleEntries = edit.apply(to: snapshot.subtitleEntries)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON([
            "id": id.uuidString,
            "isEnabled": !clip.isEnabled,
            "timelineDuration": Shared.seconds(snapshot.timeline.duration),
        ])
    }

    /// Подрезка клипа в координатах его исходника
    static func trimClip(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard let clip = snapshot.timeline.clips.first(where: { $0.id == id }) else {
            throw CLIError.notFound("клип \(id.uuidString)")
        }
        let start = args.double("source-start") ?? CMTimeGetSeconds(clip.sourceRange.start)
        let duration = args.double("duration") ?? CMTimeGetSeconds(clip.sourceRange.duration)

        let edit = snapshot.timeline.trimClip(id: id, newSourceRange: CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        ))
        snapshot.subtitleEntries = edit.apply(to: snapshot.subtitleEntries)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON([
            "trimmed": id.uuidString,
            "timelineDuration": Shared.seconds(snapshot.timeline.duration),
        ])
    }

    /// Кадрирование клипа: статичное или с наездом от начала к концу.
    ///
    /// Сдвиг задаётся в долях холста от центра: 0.1 по X — это десятая часть ширины
    /// кадра вправо. Масштаб 1.0 — кадр заполнен целиком, 1.6 — наезд в полтора раза.
    static func setFraming(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard let index = snapshot.timeline.clips.firstIndex(where: { $0.id == id }) else {
            throw CLIError.notFound("клип \(id.uuidString)")
        }

        var framing = snapshot.timeline.clips[index].framing
        if let scale = args.double("scale") { framing.scale = max(0.05, scale) }
        if let x = args.double("x") { framing.offset.x = x }
        if let y = args.double("y") { framing.offset.y = y }
        snapshot.timeline.clips[index].framing = framing

        // Конечное кадрирование задаётся, только если хоть один его параметр пришёл:
        // иначе снимаем наезд и возвращаем неподвижную рамку
        let endKeys = ["end-scale", "end-x", "end-y"]
        if endKeys.contains(where: { args.double($0) != nil }) {
            var end = snapshot.timeline.clips[index].framingEnd ?? framing
            if let scale = args.double("end-scale") { end.scale = max(0.05, scale) }
            if let x = args.double("end-x") { end.offset.x = x }
            if let y = args.double("end-y") { end.offset.y = y }
            snapshot.timeline.clips[index].framingEnd = end
        } else if args.has("static") {
            snapshot.timeline.clips[index].framingEnd = nil
        }

        try Shared.save(snapshot, to: projectURL)
        let clip = snapshot.timeline.clips[index]
        Shared.printJSON([
            "clip": id.uuidString,
            "framing": ["scale": clip.framing.scale,
                        "x": clip.framing.offset.x, "y": clip.framing.offset.y],
            "framingEnd": clip.framingEnd.map {
                ["scale": $0.scale, "x": $0.offset.x, "y": $0.offset.y]
            } as Any,
        ].compactMapValues { $0 })
    }

    // MARK: - Перебивки

    /// Картинка поверх хребта; звук хребта под ней продолжает идти
    static func addOverlay(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        let fileURL = try Shared.fileArgument(args, key: "file")
        let at = try args.requireDouble("at")
        let source = try await Shared.resolveSource(fileURL, in: &snapshot.timeline)

        let full = CMTimeGetSeconds(source.duration)
        let duration = min(args.double("duration") ?? full, full)
        guard duration > 0.001 else {
            throw CLIError.invalid("Длительность перебивки нулевая: \(fileURL.lastPathComponent)")
        }

        let overlay = OverlayClip(
            sourceID: source.id,
            sourceRange: CMTimeRange(
                start: CMTime(seconds: args.double("source-start") ?? 0, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            ),
            timelineStart: CMTime(seconds: max(0, at), preferredTimescale: 600)
        )
        snapshot.timeline.overlays.append(overlay)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON([
            "added": "overlay",
            "id": overlay.id.uuidString,
            "timelineStart": Shared.round3(max(0, at)),
            "durationSeconds": Shared.round3(duration),
        ])
    }

    static func moveOverlay(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard let index = snapshot.timeline.overlays.firstIndex(where: { $0.id == id }) else {
            throw CLIError.notFound("перебивка \(id.uuidString)")
        }
        let at = max(0, try args.requireDouble("at"))
        snapshot.timeline.overlays[index].timelineStart =
            CMTime(seconds: at, preferredTimescale: 600)

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON(["moved": id.uuidString, "timelineStart": Shared.round3(at)])
    }

    static func removeOverlay(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        let before = snapshot.timeline.overlays.count
        snapshot.timeline.overlays.removeAll { $0.id == id }
        guard snapshot.timeline.overlays.count < before else {
            throw CLIError.notFound("перебивка \(id.uuidString)")
        }

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON(["removed": id.uuidString])
    }

    // MARK: - Источники

    /// Файл переехал — перепривязать источник, не собирая монтаж заново
    static func relinkSource(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)
        let id = try Shared.uuid(args.requireString("id"))

        guard let index = snapshot.timeline.sources.firstIndex(where: { $0.id == id }) else {
            throw CLIError.notFound("источник \(id.uuidString)")
        }
        let fileURL = try Shared.fileArgument(args, key: "file")
        let loaded = try await MediaSource.load(from: fileURL)

        var replacement = loaded.withID(id)
        replacement.gain = snapshot.timeline.sources[index].gain
        replacement.integratedLUFS = snapshot.timeline.sources[index].integratedLUFS
        snapshot.timeline.sources[index] = replacement

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON(["relinked": id.uuidString, "path": fileURL.path])
    }

    /// Убирает из реестра источники, на которые никто не ссылается
    static func pruneSources(_ args: Arguments) throws {
        let projectURL = try args.projectURL()
        var snapshot = try Shared.load(projectURL)

        var used = Set(snapshot.timeline.clips.map(\.sourceID))
        used.formUnion(snapshot.timeline.overlays.map(\.sourceID))
        used.formUnion(snapshot.timeline.graphics.map(\.sourceID))

        let dropped = snapshot.timeline.sources.filter { !used.contains($0.id) }
        snapshot.timeline.sources.removeAll { !used.contains($0.id) }

        try Shared.save(snapshot, to: projectURL)
        Shared.printJSON([
            "pruned": dropped.count,
            "names": dropped.map(\.displayName),
            "remaining": snapshot.timeline.sources.count,
        ])
    }
}
