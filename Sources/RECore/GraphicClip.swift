import Foundation
import CoreMedia

/// Титр, подпись или анимация поверх всего остального.
///
/// От перебивки отличается двумя вещами, и обе принципиальны. Во-первых, у графики есть
/// прозрачность: она не заменяет картинку, а лежит на ней, поэтому исходником должен быть
/// формат с альфой — ProRes 4444 или HEVC с альфа-каналом. Во-вторых, она живёт на своём
/// слое ВЫШЕ перебивок: надпись должна оставаться читаемой, когда под ней идёт b-roll.
///
/// Кадрирование намеренно отсутствует. Графика рендерится сразу в размер холста проекта
/// (Remotion получает ширину, высоту и fps из проекта), поэтому вписывать и двигать её
/// незачем — а `ClipFraming` дал бы возможность сдвинуть титр за границу кадра.
public struct GraphicClip: Identifiable, Codable, Equatable {
    public let id: UUID

    /// Ссылка на запись в реестре `EditTimeline.sources`
    public var sourceID: MediaSource.ID

    /// Что берём из исходника
    public var sourceRange: CMTimeRange

    /// Куда кладём на таймлайн
    public var timelineStart: CMTime

    public var isEnabled: Bool

    /// Откуда графика взялась — имя шаблона Remotion и его параметры.
    /// Нужно, чтобы титр можно было перерисовать, не собирая параметры заново.
    public var origin: GraphicOrigin?

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
        isEnabled: Bool = true,
        origin: GraphicOrigin? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.isEnabled = isEnabled
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, sourceRange, timelineStart, isEnabled, origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourceRange = try c.decode(CMTimeRange.self, forKey: .sourceRange)
        timelineStart = try c.decode(CMTime.self, forKey: .timelineStart)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        origin = try c.decodeIfPresent(GraphicOrigin.self, forKey: .origin)
    }
}

/// Родословная титра: каким шаблоном и с какими параметрами он отрисован.
///
/// Параметры хранятся строкой JSON, а не разобранным словарём: их форма принадлежит
/// шаблону Remotion и меняется вместе с ним, а модель монтажа не должна знать про поля
/// конкретного титра. Перерисовка — это отдать эту же строку обратно рендереру.
public struct GraphicOrigin: Codable, Equatable {
    /// Имя композиции Remotion, например `LowerThird`
    public var template: String

    /// Параметры шаблона как JSON-строка
    public var propsJSON: String

    /// Версия пакета шаблонов — по ней видно, чем именно отрисовано
    public var packVersion: String?

    public init(template: String, propsJSON: String, packVersion: String? = nil) {
        self.template = template
        self.propsJSON = propsJSON
        self.packVersion = packVersion
    }
}
