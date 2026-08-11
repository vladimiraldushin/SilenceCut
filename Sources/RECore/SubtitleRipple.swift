import Foundation
import CoreMedia

/// Сдвиг субтитров вслед за монтажом.
///
/// Субтитры хранятся во ВРЕМЕНИ ТАЙМЛАЙНА (транскрибация идёт по смонтированному звуку),
/// поэтому вставка и вырез сдвигают их ровно так же, как перебивки и титры. До появления
/// этого файла приложение при любой правке таймлайна просто стирало субтитры целиком —
/// безопасно, но расточительно: вставка заставки в начало обесценивала всю расшифровку.
///
/// Слова внутри реплики двигаются вместе с ней: их тайминги тоже в времени таймлайна,
/// и караоке-подсветка разъедется, если сдвинуть только границы реплики.
public enum SubtitleRipple {

    private static let epsilon = 0.001

    /// Раздвигает субтитры при вставке `duration` в момент `time`.
    ///
    /// Реплика, накрывшая точку вставки, растягивается: новый материал попадает внутрь
    /// произнесённой фразы, и разрывать её надвое значило бы показать один и тот же текст
    /// дважды. Растягивание оставляет подпись на экране поверх вставки — это неидеально,
    /// зато не врёт про сказанное.
    public static func applyInsertion(
        to entries: [SubtitleEntry], at time: CMTime, duration: CMTime
    ) -> [SubtitleEntry] {
        let point = CMTimeGetSeconds(time)
        let shift = CMTimeGetSeconds(duration)
        guard shift > epsilon else { return entries }

        return entries.map { entry in
            var moved = entry
            let start = CMTimeGetSeconds(entry.startTime)
            let end = CMTimeGetSeconds(entry.endTime)

            if start >= point - epsilon {
                moved.startTime = seconds(start + shift)
                moved.endTime = seconds(end + shift)
                moved.words = entry.words.map { shiftWord($0, by: shift, after: point) }
            } else if end > point + epsilon {
                // Вставка внутри реплики — конец уезжает, начало остаётся
                moved.endTime = seconds(end + shift)
                moved.words = entry.words.map { shiftWord($0, by: shift, after: point) }
            }
            return moved
        }
    }

    /// Убирает вырезанные куски из субтитров.
    ///
    /// Реплика, целиком попавшая в вырез, исчезает: сказанного в смонтированном ролике
    /// больше нет. Задетая краем — подрезается.
    public static func applyRemovals(
        to entries: [SubtitleEntry], _ removed: [CMTimeRange]
    ) -> [SubtitleEntry] {
        let spans = EditTimeline.mergedSpans(removed)
        guard !spans.isEmpty else { return entries }

        return entries.compactMap { entry in
            let start = CMTimeGetSeconds(entry.startTime)
            let end = CMTimeGetSeconds(entry.endTime)

            let newStart = EditTimeline.shifted(start, by: spans)
            let newEnd = EditTimeline.shifted(end, by: spans)
            guard newEnd - newStart > epsilon else { return nil }

            var moved = entry
            moved.startTime = seconds(newStart)
            moved.endTime = seconds(newEnd)
            moved.words = entry.words.compactMap { word in
                let wordStart = EditTimeline.shifted(CMTimeGetSeconds(word.startTime), by: spans)
                let wordEnd = EditTimeline.shifted(CMTimeGetSeconds(word.endTime), by: spans)
                guard wordEnd - wordStart > epsilon else { return nil }
                var copy = word
                copy.startTime = seconds(wordStart)
                copy.endTime = seconds(wordEnd)
                return copy
            }
            return moved
        }
    }

    private static func shiftWord(_ word: WordTiming, by shift: Double, after point: Double) -> WordTiming {
        var copy = word
        if CMTimeGetSeconds(word.startTime) >= point - epsilon {
            copy.startTime = seconds(CMTimeGetSeconds(word.startTime) + shift)
        }
        if CMTimeGetSeconds(word.endTime) >= point - epsilon {
            copy.endTime = seconds(CMTimeGetSeconds(word.endTime) + shift)
        }
        return copy
    }

    private static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: max(0, value), preferredTimescale: 600)
    }
}
