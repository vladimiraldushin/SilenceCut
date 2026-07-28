import Foundation

/// Слепок проекта для сохранения на диск (.silencecut sidecar рядом с видео)
public struct ProjectSnapshot: Codable {
    public var name: String
    public var timeline: EditTimeline
    public var subtitleEntries: [SubtitleEntry]
    public var subtitleStyle: SubtitleStyle
    public var savedAt: Date
    /// Опционально — проекты, сохранённые до появления настроек рендера, читаются как nil
    public var renderOptions: RenderOptions?

    public init(
        name: String,
        timeline: EditTimeline,
        subtitleEntries: [SubtitleEntry],
        subtitleStyle: SubtitleStyle,
        savedAt: Date = Date(),
        renderOptions: RenderOptions? = nil
    ) {
        self.name = name
        self.timeline = timeline
        self.subtitleEntries = subtitleEntries
        self.subtitleStyle = subtitleStyle
        self.savedAt = savedAt
        self.renderOptions = renderOptions
    }
}

/// Персистентность проекта — sidecar-файл `<видео>.silencecut` рядом с исходником
public enum ProjectStore {
    /// URL sidecar-файла: <путь видео>.silencecut
    public static func sidecarURL(for videoURL: URL) -> URL {
        videoURL.appendingPathExtension("silencecut")
    }

    /// Атомарная запись JSON (ISO8601 даты, читаемое форматирование для git)
    public static func save(_ snapshot: ProjectSnapshot, for videoURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: sidecarURL(for: videoURL), options: .atomic)
    }

    /// nil если файла нет или он не читается/не парсится (не бросает)
    public static func load(for videoURL: URL) -> ProjectSnapshot? {
        try? load(from: sidecarURL(for: videoURL))
    }

    /// Прямое чтение .silencecut файла (бросает при ошибке)
    public static func load(from url: URL) throws -> ProjectSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectSnapshot.self, from: data)
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
