import Foundation
import CoreMedia
import RECore

/// Экспортирует субтитры в SRT и WebVTT рядом с видеофайлом.
/// Тайминги в SubtitleEntry уже в timeline-времени и совпадают с готовым видео.
public enum SubtitleSRTExporter {

    /// Записывает `<имя видео>.srt` рядом с видеофайлом. Возвращает URL созданного файла.
    @discardableResult
    public static func writeSRT(entries: [SubtitleEntry], videoURL: URL) throws -> URL {
        let srtURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
        try srtText(entries: entries).write(to: srtURL, atomically: true, encoding: .utf8)
        return srtURL
    }

    /// Записывает `<имя видео>.vtt` рядом с видеофайлом. Возвращает URL созданного файла.
    @discardableResult
    public static func writeVTT(entries: [SubtitleEntry], videoURL: URL) throws -> URL {
        let vttURL = videoURL.deletingPathExtension().appendingPathExtension("vtt")
        try vttText(entries: entries).write(to: vttURL, atomically: true, encoding: .utf8)
        return vttURL
    }

    /// Нумерованные блоки, таймкод с запятой перед миллисекундами.
    static func srtText(entries: [SubtitleEntry]) -> String {
        var lines: [String] = []
        var index = 1
        for entry in entries {
            let start = CMTimeGetSeconds(entry.startTime)
            let end = CMTimeGetSeconds(entry.endTime)
            guard end > start, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append("\(index)")
            lines.append("\(timecode(start, separator: ",")) --> \(timecode(end, separator: ","))")
            lines.append(entry.text)
            lines.append("")
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Заголовок WEBVTT, блоки без номеров, таймкод с точкой перед миллисекундами.
    static func vttText(entries: [SubtitleEntry]) -> String {
        var lines: [String] = ["WEBVTT", ""]
        for entry in entries {
            let start = CMTimeGetSeconds(entry.startTime)
            let end = CMTimeGetSeconds(entry.endTime)
            guard end > start, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append("\(timecode(start, separator: ".")) --> \(timecode(end, separator: "."))")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func timecode(_ seconds: Double, separator: String) -> String {
        let totalMs = max(0, Int((seconds * 1000).rounded()))
        let ms = totalMs % 1000
        let totalSeconds = totalMs / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d", h, m, s) + separator + String(format: "%03d", ms)
    }
}
