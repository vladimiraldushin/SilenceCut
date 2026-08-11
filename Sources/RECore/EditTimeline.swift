import Foundation
import CoreMedia

/// The Edit Decision List — ordered array of clips forming the edited video.
/// All timeline operations manipulate this model, then CompositionBuilder
/// rebuilds AVMutableComposition from scratch.
public struct EditTimeline: Codable, Equatable {
    /// Реестр исходников проекта. Лежит внутри EDL, а не в `Project`, чтобы модель монтажа
    /// оставалась самодостаточной: сборщик композиции, экспорт и снимки undo принимают
    /// одну структуру и не обрастают вторым параметром с реестром.
    public var sources: [MediaSource]

    /// Хребет: связанные видео и звук. По нему работают вырезание пауз, риппл и субтитры.
    public var clips: [TimelineClip]

    /// Перебивки: картинка поверх хребта, звук хребта продолжает идти под ней
    public var overlays: [OverlayClip]

    /// Титры и анимация с прозрачностью — слой выше перебивок
    public var graphics: [GraphicClip]

    public init(
        sources: [MediaSource] = [],
        clips: [TimelineClip] = [],
        overlays: [OverlayClip] = [],
        graphics: [GraphicClip] = []
    ) {
        self.sources = sources
        self.clips = clips
        self.overlays = overlays
        self.graphics = graphics
    }

    public func source(for id: MediaSource.ID) -> MediaSource? {
        sources.first { $0.id == id }
    }

    enum CodingKeys: String, CodingKey { case sources, clips, overlays, graphics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([MediaSource].self, forKey: .sources) ?? []
        clips = try c.decode([TimelineClip].self, forKey: .clips)
        overlays = try c.decodeIfPresent([OverlayClip].self, forKey: .overlays) ?? []
        graphics = try c.decodeIfPresent([GraphicClip].self, forKey: .graphics) ?? []
    }

    /// Total duration of the edited timeline (only enabled clips)
    public var duration: CMTime {
        clips.filter(\.isEnabled).reduce(CMTime.zero) { CMTimeAdd($0, $1.effectiveDuration) }
    }

    /// Number of enabled clips
    public var enabledClipCount: Int {
        clips.filter(\.isEnabled).count
    }

    // MARK: - Timeline Operations

    /// Recalculate all timelineOffsets based on clip order (ripple)
    public mutating func recalculateOffsets() {
        var offset = CMTime.zero
        for i in clips.indices {
            clips[i].timelineOffset = offset
            if clips[i].isEnabled {
                offset = CMTimeAdd(offset, clips[i].effectiveDuration)
            }
        }
    }

    /// Split a clip at a given timeline time
    public mutating func splitClip(at clipIndex: Int, splitTime: CMTime) {
        guard clipIndex >= 0 && clipIndex < clips.count else { return }
        let clip = clips[clipIndex]
        let offsetInClip = CMTimeSubtract(splitTime, clip.timelineOffset)

        // Validate split point is within the clip
        guard CMTimeCompare(offsetInClip, .zero) > 0,
              CMTimeCompare(offsetInClip, clip.effectiveDuration) < 0 else { return }

        let sourceSplitPoint = CMTimeAdd(clip.sourceRange.start, offsetInClip)

        var firstHalf = clip
        firstHalf.sourceRange = CMTimeRange(start: clip.sourceRange.start, duration: offsetInClip)

        let secondHalf = TimelineClip(
            id: UUID(),
            sourceID: clip.sourceID,
            availableRange: clip.availableRange,
            sourceRange: CMTimeRange(
                start: sourceSplitPoint,
                duration: CMTimeSubtract(clip.sourceRange.duration, offsetInClip)
            ),
            timelineOffset: splitTime,
            speed: clip.speed,
            isEnabled: clip.isEnabled,
            framing: clip.framing
        )

        clips[clipIndex] = firstHalf
        clips.insert(secondHalf, at: clipIndex + 1)
        recalculateOffsets()
    }

    /// Delete a clip by index
    public mutating func deleteClip(at clipIndex: Int) {
        guard clipIndex >= 0 && clipIndex < clips.count else { return }
        clips.remove(at: clipIndex)
        recalculateOffsets()
    }

    /// Delete a clip by ID
    /// Удаляет клип, подтягивая за собой перебивки и графику.
    ///
    /// Раньше здесь было просто `removeAll` плюс пересчёт офсетов, и всё приколотое ко
    /// времени оставалось на прежних секундах — то есть титр после удаления клипа
    /// показывался поверх уже другого материала.
    @discardableResult
    public mutating func deleteClip(id: UUID) -> TimelineEdit {
        guard let clip = clips.first(where: { $0.id == id }) else { return .none }
        let removed = clip.isEnabled ? [clip.timelineRangeOnSpine] : []
        clips.removeAll { $0.id == id }
        applyRemovals(removed)
        recalculateOffsets()
        return TimelineEdit(removed: removed)
    }

    /// Выключает или включает клип в выводе. Для всего приколотого ко времени это
    /// равносильно вырезу или вставке его куска — иначе титры разъедутся.
    @discardableResult
    public mutating func toggleClip(id: UUID) -> TimelineEdit {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return .none }
        let clip = clips[idx]
        let span = clip.timelineRangeOnSpine

        clips[idx].isEnabled.toggle()
        recalculateOffsets()
        if clip.isEnabled {
            applyRemovals([span])
            return TimelineEdit(removed: [span])
        }
        applyInsertion(at: span.start, duration: span.duration)
        return TimelineEdit(insertedAt: span.start, insertedDuration: span.duration)
    }

    /// Подрезает клип, подтягивая за собой перебивки и графику.
    ///
    /// Что именно уехало, зависит от стороны: сдвинули начало — исчез кусок в голове клипа,
    /// сдвинули конец — в хвосте. Считать это надо в СТАРЫХ координатах таймлайна, до
    /// пересчёта офсетов, иначе смещение получится от уже уехавших позиций.
    @discardableResult
    public mutating func trimClip(id: UUID, newSourceRange: CMTimeRange) -> TimelineEdit {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return .none }
        let clip = clips[idx]

        // Зажимаем в пределы доступного — растянуть клип дальше исходника нельзя
        let clampedStart = max(
            CMTimeGetSeconds(clip.availableRange.start),
            CMTimeGetSeconds(newSourceRange.start)
        )
        let clampedEnd = min(
            CMTimeGetSeconds(CMTimeRangeGetEnd(clip.availableRange)),
            CMTimeGetSeconds(CMTimeRangeGetEnd(newSourceRange))
        )
        let newDuration = max(0.01, clampedEnd - clampedStart)

        let oldStart = CMTimeGetSeconds(clip.sourceRange.start)
        let oldEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange))
        let offset = CMTimeGetSeconds(clip.timelineOffset)
        let oldLength = CMTimeGetSeconds(clip.effectiveDuration)
        let speed = clip.speed

        clips[idx].sourceRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            duration: CMTime(seconds: newDuration, preferredTimescale: 600)
        )

        let headCut = (clampedStart - oldStart) / speed
        let tailCut = (oldEnd - clampedEnd) / speed

        var removals: [CMTimeRange] = []
        if headCut > Self.trimEpsilon {
            removals.append(CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 600),
                duration: CMTime(seconds: headCut, preferredTimescale: 600)
            ))
        }
        if tailCut > Self.trimEpsilon {
            removals.append(CMTimeRange(
                start: CMTime(seconds: offset + oldLength - tailCut, preferredTimescale: 600),
                duration: CMTime(seconds: tailCut, preferredTimescale: 600)
            ))
        }
        if !removals.isEmpty {
            applyRemovals(removals)
        }

        // Клип растянули обратно — таймлайн раздвинулся, приколотое едет вправо
        let grown = -min(headCut, 0) - min(tailCut, 0)
        var edit = TimelineEdit(removed: removals)
        if grown > Self.trimEpsilon {
            let at = CMTime(seconds: offset + oldLength, preferredTimescale: 600)
            let duration = CMTime(seconds: grown, preferredTimescale: 600)
            applyInsertion(at: at, duration: duration)
            edit.insertedAt = at
            edit.insertedDuration = duration
        }

        recalculateOffsets()
        return edit
    }

    private static let trimEpsilon = 0.001

    /// Таймлайн из одного источника по найденным диапазонам речи — пакетная обработка
    /// собирает проект именно так, без ручного монтажа
    public static func singleSource(_ source: MediaSource, speechRanges: [CMTimeRange]) -> EditTimeline {
        let available = CMTimeRange(start: .zero, duration: source.duration)
        var timeline = EditTimeline(
            sources: [source],
            clips: speechRanges.map {
                TimelineClip(sourceID: source.id, availableRange: available, sourceRange: $0)
            }
        )
        timeline.recalculateOffsets()
        return timeline
    }

    /// Find clip index at a given timeline time
    public func clipIndex(at time: CMTime) -> Int? {
        for (i, clip) in clips.enumerated() where clip.isEnabled {
            if CMTimeCompare(time, clip.timelineOffset) >= 0 &&
               CMTimeCompare(time, clip.timelineEnd) < 0 {
                return i
            }
        }
        return nil
    }

    // MARK: - Source ↔ Timeline Time Mapping

    /// Map source video time to edited timeline time.
    /// Returns nil if the source time falls in a removed/disabled region.
    public func timelineTime(forSourceTime sourceTime: CMTime) -> CMTime? {
        for clip in clips where clip.isEnabled {
            let clipSourceEnd = CMTimeRangeGetEnd(clip.sourceRange)
            if CMTimeCompare(sourceTime, clip.sourceRange.start) >= 0 &&
               CMTimeCompare(sourceTime, clipSourceEnd) < 0 {
                let offsetInClip = CMTimeSubtract(sourceTime, clip.sourceRange.start)
                let scaledOffset = CMTimeMultiplyByFloat64(offsetInClip, multiplier: 1.0 / clip.speed)
                return CMTimeAdd(clip.timelineOffset, scaledOffset)
            }
        }
        return nil
    }

    /// Map edited timeline time back to source video time.
    /// Returns nil if timeline time is out of range.
    public func sourceTime(forTimelineTime timelineTime: CMTime) -> CMTime? {
        for clip in clips where clip.isEnabled {
            if CMTimeCompare(timelineTime, clip.timelineOffset) >= 0 &&
               CMTimeCompare(timelineTime, clip.timelineEnd) < 0 {
                let offsetInTimeline = CMTimeSubtract(timelineTime, clip.timelineOffset)
                let sourceOffset = CMTimeMultiplyByFloat64(offsetInTimeline, multiplier: clip.speed)
                return CMTimeAdd(clip.sourceRange.start, sourceOffset)
            }
        }
        return nil
    }

}
