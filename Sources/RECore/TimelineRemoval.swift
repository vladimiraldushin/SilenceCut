import Foundation
import CoreMedia

/// Укорачивание таймлайна: единственный путь, по которому вырезание чего-либо доезжает
/// до перебивок. Вся математика чистая и считается в секундах — так же, как в `trimClip`.
extension EditTimeline {

    /// Полуинтервал [start, end) в секундах таймлайна
    struct Span: Equatable {
        var start: Double
        var end: Double
        var length: Double { max(0, end - start) }
    }

    private static let epsilon = 0.001

    /// Сортирует диапазоны и сливает пересекающиеся: иначе перекрывающиеся вырезы
    /// посчитаются дважды и всё, что после них, уедет слишком далеко
    static func mergedSpans(_ ranges: [CMTimeRange]) -> [Span] {
        let sorted = ranges
            .map { Span(start: CMTimeGetSeconds($0.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd($0))) }
            .filter { $0.length > epsilon }
            .sorted { $0.start < $1.start }

        var merged: [Span] = []
        for span in sorted {
            if var last = merged.last, span.start <= last.end + epsilon {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Куда переедет момент `time` после вырезания `spans`
    static func shifted(_ time: Double, by spans: [Span]) -> Double {
        var removedBefore = 0.0
        for span in spans {
            if span.end <= time {
                removedBefore += span.length
            } else if span.start < time {
                removedBefore += time - span.start
            } else {
                break
            }
        }
        return time - removedBefore
    }

    /// Части `span`, не попавшие ни в один из вырезаемых кусков
    static func surviving(_ span: Span, after spans: [Span]) -> [Span] {
        var pieces: [Span] = []
        var cursor = span.start
        for cut in spans where cut.end > span.start && cut.start < span.end {
            let cutStart = max(cut.start, span.start)
            if cutStart > cursor + epsilon {
                pieces.append(Span(start: cursor, end: cutStart))
            }
            cursor = max(cursor, min(cut.end, span.end))
        }
        if span.end > cursor + epsilon {
            pieces.append(Span(start: cursor, end: span.end))
        }
        return pieces
    }

    /// Убирает из таймлайна перечисленные диапазоны, приводя перебивки в соответствие.
    ///
    /// Диапазоны задаются в СТАРОМ времени таймлайна — до укорачивания. Клипы хребта эта
    /// функция не трогает: их правит вызывающий код, здесь только перебивки.
    ///
    /// Кадры перебивки, лежавшие в вырезанном куске, исчезают вместе с ним. Поэтому вырез
    /// внутри перебивки разбивает её надвое, а вырез с краю — подрезает.
    public mutating func applyRemovals(_ removed: [CMTimeRange]) {
        let spans = Self.mergedSpans(removed)
        guard !spans.isEmpty else { return }

        var result: [OverlayClip] = []
        for overlay in overlays {
            let start = CMTimeGetSeconds(overlay.timelineStart)
            let sourceStart = CMTimeGetSeconds(overlay.sourceRange.start)
            let whole = Span(start: start, end: start + CMTimeGetSeconds(overlay.sourceRange.duration))

            var isFirstPiece = true
            for piece in Self.surviving(whole, after: spans) {
                var copy = overlay
                // Первый уцелевший кусок наследует id — выделение и undo не теряют перебивку
                if !isFirstPiece {
                    copy = OverlayClip(
                        id: UUID(),
                        sourceID: overlay.sourceID,
                        sourceRange: overlay.sourceRange,
                        timelineStart: overlay.timelineStart,
                        framing: overlay.framing,
                        isEnabled: overlay.isEnabled
                    )
                }
                isFirstPiece = false

                copy.sourceRange = CMTimeRange(
                    start: CMTime(seconds: sourceStart + (piece.start - start), preferredTimescale: 600),
                    duration: CMTime(seconds: piece.length, preferredTimescale: 600)
                )
                copy.timelineStart = CMTime(
                    seconds: Self.shifted(piece.start, by: spans),
                    preferredTimescale: 600
                )
                result.append(copy)
            }
        }
        overlays = result
    }

    /// Заменяет клип хребта набором клипов по диапазонам речи (в координатах его исходника)
    /// и подтягивает за собой перебивки. Соседние клипы не трогаются — этим детекция пауз
    /// отличается от прежней пересборки таймлайна с нуля.
    public mutating func splitClipBySpeechRanges(clipID: TimelineClip.ID, speechRanges: [CMTimeRange]) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clips[index]

        let clipSourceStart = CMTimeGetSeconds(clip.sourceRange.start)
        let clipSourceEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange))
        let timelineStart = CMTimeGetSeconds(clip.timelineOffset)

        // Время исходника → время таймлайна внутри этого клипа
        func toTimeline(_ sourceTime: Double) -> Double {
            timelineStart + (sourceTime - clipSourceStart) / clip.speed
        }

        let speech = speechRanges
            .map { Span(start: CMTimeGetSeconds($0.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd($0))) }
            .map { Span(start: max($0.start, clipSourceStart), end: min($0.end, clipSourceEnd)) }
            .filter { $0.length > Self.epsilon }
            .sorted { $0.start < $1.start }

        // Вырезаемое — дополнение речи внутри клипа, сразу в координатах таймлайна
        var removals: [CMTimeRange] = []
        var cursor = clipSourceStart
        for span in speech {
            if span.start > cursor + Self.epsilon {
                removals.append(CMTimeRange(
                    start: CMTime(seconds: toTimeline(cursor), preferredTimescale: 600),
                    duration: CMTime(seconds: (span.start - cursor) / clip.speed, preferredTimescale: 600)
                ))
            }
            cursor = max(cursor, span.end)
        }
        if clipSourceEnd > cursor + Self.epsilon {
            removals.append(CMTimeRange(
                start: CMTime(seconds: toTimeline(cursor), preferredTimescale: 600),
                duration: CMTime(seconds: (clipSourceEnd - cursor) / clip.speed, preferredTimescale: 600)
            ))
        }

        let replacements = speech.map { span in
            TimelineClip(
                sourceID: clip.sourceID,
                availableRange: clip.availableRange,
                sourceRange: CMTimeRange(
                    start: CMTime(seconds: span.start, preferredTimescale: 600),
                    duration: CMTime(seconds: span.length, preferredTimescale: 600)
                ),
                timelineOffset: clip.timelineOffset,
                speed: clip.speed,
                isEnabled: clip.isEnabled,
                framing: clip.framing
            )
        }

        clips.replaceSubrange(index...index, with: replacements)
        applyRemovals(removals)
        recalculateOffsets()
    }

    /// Перебивки, обрезанные по фактической длине хребта: вылезшая за конец картинка
    /// не должна дотягивать композицию до пустоты
    public var clampedOverlays: [OverlayClip] {
        let end = CMTimeGetSeconds(duration)
        return overlays.compactMap { overlay in
            guard overlay.isEnabled else { return nil }
            let start = CMTimeGetSeconds(overlay.timelineStart)
            guard start < end - Self.epsilon else { return nil }
            let available = min(CMTimeGetSeconds(overlay.sourceRange.duration), end - start)
            guard available > Self.epsilon else { return nil }

            var clamped = overlay
            clamped.sourceRange = CMTimeRange(
                start: overlay.sourceRange.start,
                duration: CMTime(seconds: available, preferredTimescale: 600)
            )
            return clamped
        }
    }
}
