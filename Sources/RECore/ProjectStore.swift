import Foundation

/// Слепок проекта для сохранения на диск (файл .silencecut)
public struct ProjectSnapshot: Codable {
    /// 1 — источник хранился прямо в клипе, реестра не было. 2 — реестр в `timeline.sources`.
    /// У файлов первой версии поля нет, поэтому оно читается как 1.
    public var version: Int

    public var name: String
    public var timeline: EditTimeline
    public var subtitleEntries: [SubtitleEntry]
    public var subtitleStyle: SubtitleStyle
    public var savedAt: Date
    /// Опционально — проекты, сохранённые до появления настроек рендера, читаются как nil
    public var renderOptions: RenderOptions?

    public static let currentVersion = 2

    public init(
        name: String,
        timeline: EditTimeline,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        savedAt: Date = Date(),
        renderOptions: RenderOptions? = nil,
        version: Int = ProjectSnapshot.currentVersion
    ) {
        self.version = version
        self.name = name
        self.timeline = timeline
        self.subtitleEntries = subtitleEntries
        self.subtitleStyle = subtitleStyle
        self.savedAt = savedAt
        self.renderOptions = renderOptions
    }

    enum CodingKeys: String, CodingKey {
        case version, name, timeline, subtitleEntries, subtitleStyle, savedAt, renderOptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decode(String.self, forKey: .name)
        timeline = try c.decode(EditTimeline.self, forKey: .timeline)
        subtitleEntries = try c.decode([SubtitleEntry].self, forKey: .subtitleEntries)
        subtitleStyle = try c.decode(SubtitleStyle.self, forKey: .subtitleStyle)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        renderOptions = try c.decodeIfPresent(RenderOptions.self, forKey: .renderOptions)
    }
}

/// Персистентность проекта — самостоятельный файл `.silencecut` в любом месте диска.
///
/// Раньше проект жил sidecar'ом рядом с главным видео и подхватывался по пути исходника.
/// С несколькими источниками привязка к одному файлу перестала иметь смысл, поэтому проект
/// стал обычным документом: путь к нему знает вьюмодель, список — `RecentProjectsStore`.
/// Формат не менялся, так что старые sidecar-файлы открываются через «Открыть проект…».
public enum ProjectStore {
    public static let fileExtension = "silencecut"

    /// Атомарная запись JSON (ISO8601 даты, читаемое форматирование для git)
    public static func save(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Прямое чтение .silencecut файла (бросает при ошибке)
    public static func load(from url: URL) throws -> ProjectSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshot = try decoder.decode(ProjectSnapshot.self, from: data)
        if snapshot.version < 2 {
            migrateToRegistry(&snapshot)
        }
        return snapshot
    }

    /// Проект первой версии: собрать реестр из URL, разложенных по клипам.
    ///
    /// Метаданные кадра здесь заглушечные: `ProjectStore` синхронный и не может ждать
    /// `AVURLAsset`. Настоящие значения дозаполняет вьюмодель при импорте — она всё равно
    /// открывает каждый файл, чтобы построить превью.
    private static func migrateToRegistry(_ snapshot: inout ProjectSnapshot) {
        var sourcesByPath: [String: MediaSource] = [:]
        var order: [String] = []

        for clip in snapshot.timeline.clips {
            guard let url = clip.legacySourceURL else { continue }
            let key = url.path
            if sourcesByPath[key] == nil {
                sourcesByPath[key] = MediaSource(
                    url: url,
                    duration: clip.availableRange.duration,
                    naturalSize: .zero,
                    preferredTransform: .identity,
                    nominalFrameRate: 30,
                    hasAudio: true
                )
                order.append(key)
            }
        }

        for index in snapshot.timeline.clips.indices {
            guard let url = snapshot.timeline.clips[index].legacySourceURL,
                  let source = sourcesByPath[url.path] else { continue }
            snapshot.timeline.clips[index].sourceID = source.id
            snapshot.timeline.clips[index].legacySourceURL = nil
        }

        snapshot.timeline.sources = order.compactMap { sourcesByPath[$0] }
    }
}

/// Именованные пользовательские пресеты стиля субтитров (UserDefaults, JSON)
public enum SubtitleStylePresetStore {
    private static let key = "silencecut.stylePresets"

    /// Подменяемое хранилище для тестов, по умолчанию .standard
    static var defaults: UserDefaults = .standard

    private static func loadPresets() -> [String: Data] {
        defaults.object(forKey: key) as? [String: Data] ?? [:]
    }

    private static func savePresets(_ presets: [String: Data]) {
        defaults.set(presets, forKey: key)
    }

    /// Имена сохранённых пресетов, отсортированы
    public static func names() -> [String] {
        loadPresets().keys.sorted()
    }

    public static func save(_ style: SubtitleStyle, named name: String) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        var presets = loadPresets()
        presets[name] = data
        savePresets(presets)
    }

    public static func load(named name: String) -> SubtitleStyle? {
        guard let data = loadPresets()[name] else { return nil }
        return try? JSONDecoder().decode(SubtitleStyle.self, from: data)
    }

    public static func delete(named name: String) {
        var presets = loadPresets()
        presets.removeValue(forKey: name)
        savePresets(presets)
    }
}
