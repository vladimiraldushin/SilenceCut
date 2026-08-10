import Foundation
import CoreMedia

/// Перебивка — картинка поверх хребта на заданном куске таймлайна.
///
/// Своего звука у неё нет намеренно: речь и, значит, детекция пауз с субтитрами остаются
/// привязаны к одному непрерывному потоку хребта. Длительность выводится из `sourceRange`
/// и отдельно не хранится — рассинхрону неоткуда взяться.
public struct OverlayClip: Identifiable, Codable, Equatable {
    public let id: UUID

    /// Ссылка на запись в реестре `EditTimeline.sources`
    public var sourceID: MediaSource.ID

    /// Что берём из исходника
    public var sourceRange: CMTimeRange

    /// Куда кладём на таймлайн
    public var timelineStart: CMTime

    /// Как кадр перебивки ложится на холст проекта
    public var framing: ClipFraming

    public var isEnabled: Bool

    public var timelineRange: CMTimeRange {
        CMTimeRange(start: timelineStart, duration: sourceRange.duration)
    }

    public var timelineEnd: CMTime {
        CMTimeAdd(timelineStart, sourceRange.duration)
    }

    public init(
        id: UUID = UUID(),
        sourceID: MediaSource.ID,
        sourceRange: CMTimeRange,
        timelineStart: CMTime,
        framing: ClipFraming = .default,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.framing = framing
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey { case id, sourceID, sourceRange, timelineStart, framing, isEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourceRange = try c.decode(CMTimeRange.self, forKey: .sourceRange)
        timelineStart = try c.decode(CMTime.self, forKey: .timelineStart)
        framing = try c.decodeIfPresent(ClipFraming.self, forKey: .framing) ?? .default
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
