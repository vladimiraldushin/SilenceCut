import Foundation
import CoreMedia

/// Клип, приколотый к месту на таймлайне, а не выстроенный в очередь: перебивка и графика.
///
/// Хребет — это последовательность, его позиции пересчитываются из порядка. Всё остальное
/// живёт по абсолютному времени, и потому одинаково реагирует на укорачивание и раздвигание
/// таймлайна. Общий протокол существует ровно ради этого: риппл написан один раз, и перебивки
/// с графикой не могут разъехаться в поведении при следующей правке.
public protocol PinnedClip: Identifiable, Equatable {
    var sourceID: MediaSource.ID { get }
    var sourceRange: CMTimeRange { get set }
    var timelineStart: CMTime { get set }
    var isEnabled: Bool { get }

    /// Копия с новым идентификатором — нужна, когда вырез разбивает клип надвое
    func splitCopy() -> Self
}

extension OverlayClip: PinnedClip {
    public func splitCopy() -> OverlayClip {
        OverlayClip(
            id: UUID(),
            sourceID: sourceID,
            sourceRange: sourceRange,
            timelineStart: timelineStart,
            framing: framing,
            isEnabled: isEnabled
        )
    }
}

extension GraphicClip: PinnedClip {
    public func splitCopy() -> GraphicClip {
        GraphicClip(
            id: UUID(),
            sourceID: sourceID,
            sourceRange: sourceRange,
            timelineStart: timelineStart,
            isEnabled: isEnabled,
            origin: origin
        )
    }
}
