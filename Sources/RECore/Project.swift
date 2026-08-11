import Foundation

/// Represents a saved editing project.
/// Источники живут в `timeline.sources` — модель монтажа самодостаточна, и проект
/// не дублирует ссылку на «тот самый» файл.
public struct Project: Codable {
    public var name: String
    public var timeline: EditTimeline
    public var createdAt: Date
    public var modifiedAt: Date

    /// Главный источник — первый добавленный. Определяет формат кадра и fps проекта.
    public var mainSource: MediaSource? { timeline.sources.first }

    public init(name: String = "Untitled", timeline: EditTimeline = EditTimeline()) {
        self.name = name
        self.timeline = timeline
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
}
