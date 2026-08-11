import Foundation
import CoreMedia

/// Что операция сделала со временем таймлайна.
///
/// Субтитры живут вне `EditTimeline` (они в `ProjectSnapshot`), поэтому сдвинуть их
/// изнутри операция не может. Возвращать описание правки вместо того, чтобы вызывающий
/// код заново считал ту же математику, — единственный способ не дать субтитрам и
/// перебивкам разъехаться при следующей правке модели.
public struct TimelineEdit: Equatable {
    /// Куски, исчезнувшие из таймлайна, в СТАРЫХ координатах
    public var removed: [CMTimeRange]

    /// Точка и длина раздвигания
    public var insertedAt: CMTime?
    public var insertedDuration: CMTime?

    public static let none = TimelineEdit(removed: [])

    public init(removed: [CMTimeRange] = [], insertedAt: CMTime? = nil, insertedDuration: CMTime? = nil) {
        self.removed = removed
        self.insertedAt = insertedAt
        self.insertedDuration = insertedDuration
    }

    /// Применяет ту же правку к субтитрам
    public func apply(to entries: [SubtitleEntry]) -> [SubtitleEntry] {
        var result = entries
        if !removed.isEmpty {
            result = SubtitleRipple.applyRemovals(to: result, removed)
        }
        if let insertedAt, let insertedDuration {
            result = SubtitleRipple.applyInsertion(to: result, at: insertedAt, duration: insertedDuration)
        }
        return result
    }
}
