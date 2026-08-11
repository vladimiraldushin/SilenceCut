import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RECore
import RETimeline

/// Снятие кадров с СОБРАННОГО таймлайна.
///
/// Выдёргивать кадры из исходников напрямую нельзя: в монтаже уже применены кадрирование,
/// формат холста, перебивки и титры, и по сырому файлу видно совсем не то, что попадёт в
/// вывод. Поэтому кадр берётся из той же композиции, что идёт в превью и экспорт.
///
/// Нужно это в первую очередь языковой модели: посмотреть, что происходит в ролике,
/// иначе про содержимое можно только гадать.
enum FrameCommands {

    static func frame(_ args: Arguments) async throws {
        let projectURL = try args.projectURL()
        let snapshot = try Shared.load(projectURL)
        let timeline = snapshot.timeline

        guard timeline.enabledClipCount > 0 else {
            throw CLIError.invalid("В проекте нет включённых клипов")
        }
        let missing = timeline.sources.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard missing.isEmpty else {
            throw CLIError.invalid(
                "Не найдены исходники: \(missing.map(\.displayName).joined(separator: ", "))"
            )
        }

        let total = CMTimeGetSeconds(timeline.duration)
        let times = try requestedTimes(args, total: total)
        guard !times.isEmpty else {
            throw CLIError.invalid("Не задано ни одного момента: --at или --count")
        }

        let built = try await CompositionBuilder.build(
            from: timeline, options: snapshot.renderOptions ?? .default
        )

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        // Точность важнее скорости: без этого генератор отдаёт ближайший ключевой кадр,
        // и «кадр на 42-й секунде» окажется кадром на 39-й
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Ширина уменьшённого кадра: полноразмерные 1080×1920 читать незачем
        let maxWidth = args.double("width") ?? 480
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)

        let outDir = URL(
            fileURLWithPath: ((args.string("out-dir") ?? FileManager.default.temporaryDirectory.path)
                as NSString).expandingTildeInPath
        )
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var written: [[String: Any]] = []
        var images: [CGImage] = []

        for time in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
                written.append(["at": Shared.round3(time), "error": "кадр не прочитался"])
                continue
            }
            images.append(image)

            let path = outDir.appendingPathComponent(
                String(format: "frame-%07.2f.png", time).replacingOccurrences(of: " ", with: "0")
            )
            if write(image, to: path) {
                written.append([
                    "at": Shared.round3(time),
                    "file": path.path,
                    "clip": clipDescription(at: cmTime, timeline: timeline) as Any,
                ].compactMapValues { $0 })
            }
        }

        var payload: [String: Any] = [
            "project": projectURL.path,
            "durationSeconds": Shared.round3(total),
            "frames": written,
        ]

        // Один лист вместо десятка файлов: так весь ролик видно за один взгляд
        if args.has("sheet"), !images.isEmpty {
            let sheetURL = outDir.appendingPathComponent("contact-sheet.png")
            if let sheet = contactSheet(images, columns: Int(args.double("columns") ?? 5)),
               write(sheet, to: sheetURL) {
                payload["sheet"] = sheetURL.path
            }
        }

        Shared.printJSON(payload)
    }

    // MARK: - Выбор моментов

    private static func requestedTimes(_ args: Arguments, total: Double) throws -> [Double] {
        if let list = args.string("at") {
            return list.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            }.map { max(0, min($0, total - 0.05)) }
        }
        if let count = args.double("count"), count >= 1 {
            let n = Int(count)
            // Сдвиг на полшага: кадр из середины отрезка вместо его границы, где
            // с большой вероятностью стоит склейка
            return (0..<n).map { total * (Double($0) + 0.5) / Double(n) }
        }
        if let every = args.double("every"), every > 0 {
            return stride(from: 0, to: total, by: every).map { $0 }
        }
        return []
    }

    /// Какой клип и исходник звучит в этот момент — без этого кадр висит в воздухе
    private static func clipDescription(at time: CMTime, timeline: EditTimeline) -> String? {
        guard let index = timeline.clipIndex(at: time) else { return nil }
        let clip = timeline.clips[index]
        let name = timeline.source(for: clip.sourceID)?.displayName ?? "?"
        let inSource = CMTimeGetSeconds(clip.sourceRange.start)
            + (CMTimeGetSeconds(time) - CMTimeGetSeconds(clip.timelineOffset)) * clip.speed
        return "\(name) @ \(Shared.fmt(inSource))с (клип \(index + 1) из \(timeline.clips.count))"
    }

    // MARK: - Запись

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Сетка из кадров в одном изображении
    private static func contactSheet(_ images: [CGImage], columns: Int) -> CGImage? {
        guard let first = images.first else { return nil }
        let columns = max(1, min(columns, images.count))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cellWidth = first.width
        let cellHeight = first.height
        let gap = 8

        let width = columns * cellWidth + (columns + 1) * gap
        let height = rows * cellHeight + (rows + 1) * gap

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            // CoreGraphics считает снизу вверх — переворачиваем, чтобы первый кадр был сверху
            let y = height - (row + 1) * (cellHeight + gap)
            context.draw(image, in: CGRect(
                x: gap + column * (cellWidth + gap), y: y,
                width: cellWidth, height: cellHeight
            ))
        }
        return context.makeImage()
    }
}
