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
        overlays = Self.removing(spans, from: overlays)
        graphics = Self.removing(spans, from: graphics)
    }

    /// Общий риппл для всего, что приколото ко времени таймлайна.
    ///
    /// Кадры приколотого клипа, лежавшие в вырезанном куске, исчезают вместе с ним. Поэтому
    /// вырез внутри разбивает клип надвое, а вырез с краю — подрезает.
    static func removing<Clip: PinnedClip>(_ spans: [Span], from clips: [Clip]) -> [Clip] {
        var result: [Clip] = []
        for clip in clips {
            let start = CMTimeGetSeconds(clip.timelineStart)
            let sourceStart = CMTimeGetSeconds(clip.sourceRange.start)
            let whole = Span(start: start, end: start + CMTimeGetSeconds(clip.sourceRange.duration))

            var isFirstPiece = true
            for piece in surviving(whole, after: spans) {
                // Первый уцелевший кусок наследует id — выделение и undo не теряют клип
                var copy = isFirstPiece ? clip : clip.splitCopy()
                isFirstPiece = false

                copy.sourceRange = CMTimeRange(
                    start: CMTime(seconds: sourceStart + (piece.start - start), preferredTimescale: 600),
                    duration: CMTime(seconds: piece.length, preferredTimescale: 600)
                )
                copy.timelineStart = CMTime(
                    seconds: shifted(piece.start, by: spans), preferredTimescale: 600
                )
                result.append(copy)
            }
        }
        return result
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

    // MARK: - Вставка и перестановка

    /// Раздвигает таймлайн в точке `time` на `duration`.
    ///
    /// Симметрично `applyRemovals`: кадры перебивки привязаны к своему месту на таймлайне,
    /// поэтому перебивка, накрывшая точку вставки, распадается надвое — иначе её картинка
    /// поехала бы поверх только что вставленного материала.
    public mutating func applyInsertion(at time: CMTime, duration: CMTime) {
        let point = CMTimeGetSeconds(time)
        let shift = CMTimeGetSeconds(duration)
        guard shift > Self.epsilon else { return }
        overlays = Self.inserting(at: point, shift: shift, into: overlays)
        graphics = Self.inserting(at: point, shift: shift, into: graphics)
    }

    /// Общее раздвигание для всего, что приколото ко времени таймлайна
    static func inserting<Clip: PinnedClip>(
        at point: Double, shift: Double, into clips: [Clip]
    ) -> [Clip] {
        var result: [Clip] = []
        for clip in clips {
            let start = CMTimeGetSeconds(clip.timelineStart)
            let length = CMTimeGetSeconds(clip.sourceRange.duration)
            let end = start + length

            if start >= point - epsilon {
                var moved = clip
                moved.timelineStart = CMTime(seconds: start + shift, preferredTimescale: 600)
                result.append(moved)
            } else if end <= point + epsilon {
                result.append(clip)
            } else {
                // Точка вставки внутри клипа — режем и правую половину сдвигаем
                let sourceStart = CMTimeGetSeconds(clip.sourceRange.start)
                let headLength = point - start

                var head = clip
                head.sourceRange = CMTimeRange(
                    start: clip.sourceRange.start,
                    duration: CMTime(seconds: headLength, preferredTimescale: 600)
                )
                result.append(head)

                var tail = clip.splitCopy()
                tail.sourceRange = CMTimeRange(
                    start: CMTime(seconds: sourceStart + headLength, preferredTimescale: 600),
                    duration: CMTime(seconds: length - headLength, preferredTimescale: 600)
                )
                tail.timelineStart = CMTime(seconds: point + shift, preferredTimescale: 600)
                result.append(tail)
            }
        }
        return result
    }

    /// Индекс в хребте, куда встанет клип, если бросить его в момент `time`.
    /// Считается по ближайшей границе клипов — попадать в неё пиксель в пиксель не нужно.
    public func insertIndex(atTimelineTime time: CMTime) -> Int {
        let target = CMTimeGetSeconds(time)
        let enabled = clips.filter(\.isEnabled)
        guard !enabled.isEmpty else { return 0 }

        var boundaries: [Double] = [0]
        for clip in enabled {
            boundaries.append(CMTimeGetSeconds(clip.timelineEnd))
        }
        var bestIndex = 0
        var bestDistance = Double.infinity
        for (index, boundary) in boundaries.enumerated() {
            let distance = abs(boundary - target)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Вставляет клип в момент `time`, разрезав клип под ней, и раздвигает перебивки.
    public mutating func insertClip(_ clip: TimelineClip, at time: CMTime) {
        let total = CMTimeGetSeconds(duration)
        let point = max(0, min(CMTimeGetSeconds(time), total))
        let at = CMTime(seconds: point, preferredTimescale: 600)

        // Плейхед внутри клипа — сначала разрезаем, чтобы вставка встала ровно в это место
        if let index = clipIndex(at: at) {
            let host = clips[index]
            let offsetInClip = point - CMTimeGetSeconds(host.timelineOffset)
            if offsetInClip > Self.epsilon,
               offsetInClip < CMTimeGetSeconds(host.effectiveDuration) - Self.epsilon {
                splitClip(at: index, splitTime: at)
            }
        }

        // После возможного разреза граница существует ровно в этой точке
        var insertAt = clips.count
        for (index, existing) in clips.enumerated()
        where CMTimeGetSeconds(existing.timelineOffset) >= point - Self.epsilon {
            insertAt = index
            break
        }

        var inserted = clip
        inserted.timelineOffset = at
        clips.insert(inserted, at: insertAt)

        applyInsertion(at: at, duration: inserted.effectiveDuration)
        recalculateOffsets()
    }

    /// Переставляет клип хребта к указанной ГРАНИЦЕ — номеру стыка в текущем массиве,
    /// каким его вернёт `insertIndex(atTimelineTime:)`. Границ на одну больше, чем клипов:
    /// 0 — перед первым, `clips.count` — в самый конец.
    ///
    /// Именно границы, а не конечный индекс: перетаскивание на таймлайне даёт стык, в который
    /// целится курсор, и пересчитывать его в конечную позицию должен тот, кто знает про
    /// изъятие клипа из массива, — то есть эта функция.
    ///
    /// Общая длина не меняется, поэтому перебивки остаются там, где стояли.
    public mutating func moveClip(id: TimelineClip.ID, toBoundary boundary: Int) {
        guard let from = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips.remove(at: from)
        let to = max(0, min(boundary > from ? boundary - 1 : boundary, clips.count))
        clips.insert(clip, at: to)
        recalculateOffsets()
    }

    /// Перебивки, обрезанные по фактической длине хребта: вылезшая за конец картинка
    /// не должна дотягивать композицию до пустоты
    public var clampedOverlays: [OverlayClip] {
        Self.clamped(overlays, toTimelineEnd: CMTimeGetSeconds(duration))
    }

    /// То же для графики: титр, вылезший за конец хребта, подрезается
    public var clampedGraphics: [GraphicClip] {
        Self.clamped(graphics, toTimelineEnd: CMTimeGetSeconds(duration))
    }

    static func clamped<Clip: PinnedClip>(_ clips: [Clip], toTimelineEnd end: Double) -> [Clip] {
        clips.compactMap { clip in
            guard clip.isEnabled else { return nil }
            let start = CMTimeGetSeconds(clip.timelineStart)
            guard start < end - epsilon else { return nil }
            let available = min(CMTimeGetSeconds(clip.sourceRange.duration), end - start)
            guard available > epsilon else { return nil }

            var result = clip
            result.sourceRange = CMTimeRange(
                start: clip.sourceRange.start,
                duration: CMTime(seconds: available, preferredTimescale: 600)
            )
            return result
        }
    }
}
