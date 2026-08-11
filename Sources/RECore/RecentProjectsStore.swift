import Foundation

/// Строка в списке недавних проектов. Метаданные лежат здесь, а не читаются из файла:
/// стартовый экран должен рисоваться мгновенно, не разбирая десяток JSON'ов.
public struct RecentProject: Codable, Identifiable, Equatable {
    public var id: URL { url }

    public var name: String
    public var url: URL
    /// Закладка на случай, если файл переехал: путь протухает, закладка обычно нет
    public var bookmarkData: Data?
    public var modifiedAt: Date
    public var durationSeconds: Double
    public var clipCount: Int
    public var sourceCount: Int

    public init(
        name: String,
        url: URL,
        bookmarkData: Data? = nil,
        modifiedAt: Date = Date(),
        durationSeconds: Double = 0,
        clipCount: Int = 0,
        sourceCount: Int = 0
    ) {
        self.name = name
        self.url = url
        self.bookmarkData = bookmarkData
        self.modifiedAt = modifiedAt
        self.durationSeconds = durationSeconds
        self.clipCount = clipCount
        self.sourceCount = sourceCount
    }

    /// Файл на месте? Стартовый экран помечает пропавшие проекты, но не выкидывает их сам —
    /// внешний диск может быть просто отключён
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Список недавних проектов в UserDefaults. Один проект — одна строка, ключ — путь к файлу.
public enum RecentProjectsStore {
    private static let key = "silencecut.recentProjects"
    public static let limit = 30

    /// Подменяемое хранилище для тестов, по умолчанию .standard
    public static var defaults: UserDefaults = .standard

    /// Отсортированы по дате изменения, свежие первыми
    public static func all() -> [RecentProject] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder.iso8601.decode([RecentProject].self, from: data)
        else { return [] }
        return items.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Добавляет или обновляет запись. Совпадение — по пути файла, поэтому повторное
    /// сохранение того же проекта не плодит дубликаты, а поднимает его наверх.
    public static func record(_ project: RecentProject) {
        var items = all().filter { $0.url.standardizedFileURL != project.url.standardizedFileURL }
        items.insert(project, at: 0)
        write(Array(items.prefix(limit)))
    }

    public static func remove(url: URL) {
        write(all().filter { $0.url.standardizedFileURL != url.standardizedFileURL })
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }

    private static func write(_ items: [RecentProject]) {
        guard let data = try? JSONEncoder.iso8601.encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
