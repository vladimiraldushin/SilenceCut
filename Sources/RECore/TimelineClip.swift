import Foundation
import CoreMedia

/// A clip on the timeline — the fundamental unit of non-destructive editing.
/// Stores source reference and trim points. The source file is NEVER modified.
public struct TimelineClip: Identifiable, Codable, Equatable {
    public let id: UUID

    /// Ссылка на запись в реестре `EditTimeline.sources`
    public var sourceID: MediaSource.ID

    /// Full range of the source media (never changes — enables non-destructive trim)
    public let availableRange: CMTimeRange

    /// Current trimmed range within the source (user can expand back to availableRange)
    public var sourceRange: CMTimeRange

    /// Position on the output timeline
    public var timelineOffset: CMTime

    /// Playback speed multiplier
    public var speed: Double = 1.0

    /// Whether this clip is included in the output
    public var isEnabled: Bool = true

    /// Как кадр этого клипа ложится на холст проекта
    public var framing: ClipFraming = .default

    /// Кадрирование в КОНЦЕ клипа. Если задано, кадр едет от `framing` к нему линейно.
    ///
    /// Нужно, чтобы вести человека в кадре: говорящий смещается и приближается, а
    /// неподвижная рамка либо теряет его, либо вынуждена быть настолько широкой, что
    /// крупного плана не получается.
    public var framingEnd: ClipFraming?

    /// Множитель громкости именно этого куска, 1.0 — как в исходнике.
    ///
    /// Отдельно от `MediaSource.gain`: микрофон пропадает не на весь дубль, а на
    /// отдельные реплики, и выравнивать приходится по клипам, а не по файлам.
    public var gain: Double = 1.0

    /// URL из проектов старого формата, где источник хранился прямо в клипе.
    /// Живёт только между декодированием и миграцией в `ProjectStore`; наружу не сохраняется.
    public var legacySourceURL: URL?

    /// Duration on the timeline (accounting for speed)
    public var effectiveDuration: CMTime {
        CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1.0 / speed)
    }

    /// End time on the timeline
    public var timelineEnd: CMTime {
        CMTimeAdd(timelineOffset, effectiveDuration)
    }

    public init(
        id: UUID = UUID(),
        sourceID: MediaSource.ID,
        availableRange: CMTimeRange,
        sourceRange: CMTimeRange,
        timelineOffset: CMTime = .zero,
        speed: Double = 1.0,
        isEnabled: Bool = true,
        framing: ClipFraming = .default,
        framingEnd: ClipFraming? = nil,
        gain: Double = 1.0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.availableRange = availableRange
        self.sourceRange = sourceRange
        self.timelineOffset = timelineOffset
        self.speed = speed
        self.isEnabled = isEnabled
        self.framing = framing
        self.framingEnd = framingEnd
        self.gain = gain
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, sourceID, availableRange, sourceRange, timelineOffset, speed, isEnabled, framing, framingEnd, gain
        case sourceURL   // только для чтения проектов первой версии
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        availableRange = try c.decode(CMTimeRange.self, forKey: .availableRange)
        sourceRange = try c.decode(CMTimeRange.self, forKey: .sourceRange)
        timelineOffset = try c.decode(CMTime.self, forKey: .timelineOffset)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        framing = try c.decodeIfPresent(ClipFraming.self, forKey: .framing) ?? .default
        framingEnd = try c.decodeIfPresent(ClipFraming.self, forKey: .framingEnd)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1.0

        if let id = try c.decodeIfPresent(UUID.self, forKey: .sourceID) {
            sourceID = id
            legacySourceURL = nil
        } else {
            // Проект первой версии: источник в клипе, реестра нет.
            // Настоящий id проставит миграция в ProjectStore — она видит все клипы сразу
            // и знает, какие из них ссылаются на один и тот же файл.
            sourceID = TimelineClip.unresolvedSourceID
            legacySourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(availableRange, forKey: .availableRange)
        try c.encode(sourceRange, forKey: .sourceRange)
        try c.encode(timelineOffset, forKey: .timelineOffset)
        try c.encode(speed, forKey: .speed)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(framing, forKey: .framing)
        try c.encodeIfPresent(framingEnd, forKey: .framingEnd)
        try c.encode(gain, forKey: .gain)
    }

    /// Заглушка на время между декодированием старого проекта и миграцией
    public static let unresolvedSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

// MARK: - Codable conformance for CMTime/CMTimeRange

extension CMTime: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case value, timescale }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(Int64.self, forKey: .value)
        let timescale = try c.decode(Int32.self, forKey: .timescale)
        self = CMTime(value: value, timescale: timescale)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.value, forKey: .value)
        try c.encode(self.timescale, forKey: .timescale)
    }
}

extension CMTimeRange: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case start, duration }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(CMTime.self, forKey: .start)
        let duration = try c.decode(CMTime.self, forKey: .duration)
        self = CMTimeRange(start: start, duration: duration)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.start, forKey: .start)
        try c.encode(self.duration, forKey: .duration)
    }
}

extension TimelineClip {
    /// Кусок таймлайна, который клип занимает сейчас — в координатах ДО правки.
    /// Через него укорачивание и раздвигание доезжают до перебивок и графики.
    public var timelineRangeOnSpine: CMTimeRange {
        CMTimeRange(start: timelineOffset, duration: effectiveDuration)
    }
}
