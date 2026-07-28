import Foundation
import CoreMedia
import RECore

/// Сохраняет субтитры в Markdown-файл рядом с экспортированным видео.
/// Тайминги в SubtitleEntry уже в timeline-времени и совпадают с готовым видео.
public enum SubtitleMarkdownExporter {

    /// Записывает `<имя видео>.md` рядом с видеофайлом. Возвращает URL созданного файла.
    @discardableResult
    public static func write(
        entries: [SubtitleEntry],
        videoURL: URL,
        projectName: String
    ) throws -> URL {
        let mdURL = videoURL.deletingPathExtension().appendingPathExtension("md")
        let content = markdown(entries: entries, videoName: videoURL.lastPathComponent, projectName: projectName)
        try content.write(to: mdURL, atomically: true, encoding: .utf8)
        return mdURL
    }

    /// Формирует Markdown: шапка, тайм-коды по сегментам, полный текст одним абзацем.
    static func markdown(entries: [SubtitleEntry], videoName: String, projectName: String) -> String {
        var lines: [String] = []
        lines.append("# \(projectName) — субтитры")
        lines.append("")
        lines.append("- Видео: \(videoName)")
        if let last = entries.last {
            lines.append("- Длительность: \(timecode(CMTimeGetSeconds(last.endTime)))")
        }
        lines.append("- Сегментов: \(entries.count)")
        lines.append("")
        lines.append("## Тайм-коды")
        lines.append("")
        for entry in entries {
            let start = timecode(CMTimeGetSeconds(entry.startTime))
            let end = timecode(CMTimeGetSeconds(entry.endTime))
            lines.append("**\(start)–\(end)** \(entry.text)")
            lines.append("")
        }
        lines.append("## Полный текст")
        lines.append("")
        lines.append(entries.map(\.text).joined(separator: " "))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
