import Foundation
import CoreMedia
import CoreGraphics

/// Исходник, добавленный в проект. Живёт в реестре `EditTimeline.sources`, клипы ссылаются
/// на него по `id`.
///
/// Метаданные лежат здесь, а не читаются из `AVURLAsset` на каждом клипе: при двадцати клипах
/// из одного ролика это двадцать лишних асинхронных загрузок на каждую пересборку композиции.
/// Замер громкости тоже хранится тут — после открытия проекта мерить заново не нужно.
public struct MediaSource: Identifiable, Codable, Equatable {
    public let id: UUID
    public var url: URL

    /// Security-scoped bookmark: без него доступ к файлу не переживает перезапуск приложения
    public var bookmarkData: Data?

    public var duration: CMTime
    public var naturalSize: CGSize
    public var preferredTransform: CGAffineTransform
    public var nominalFrameRate: Double
    public var hasAudio: Bool

    /// Результат замера по BS.1770, если он проводился
    public var integratedLUFS: Double?

    /// Множитель громкости этого источника — приводит разные дубли к общей громкости
    public var gain: Double

    public var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// Размер кадра с учётом поворота из `preferredTransform`
    public var orientedSize: CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        bookmarkData: Data? = nil,
        duration: CMTime,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        nominalFrameRate: Double,
        hasAudio: Bool,
        integratedLUFS: Double? = nil,
        gain: Double = 1.0
    ) {
        self.id = id
        self.url = url
        self.bookmarkData = bookmarkData
        self.duration = duration
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.nominalFrameRate = nominalFrameRate
        self.hasAudio = hasAudio
        self.integratedLUFS = integratedLUFS
        self.gain = gain
    }

    // MARK: - Codable

    // CGSize и CGAffineTransform кодируются явно списком чисел: у их системных конформансов
    // формат не зафиксирован документацией, а этот файл читается и через год.
    enum CodingKeys: String, CodingKey {
        case id, url, bookmarkData, duration
        case width, height, transform
        case nominalFrameRate, hasAudio, integratedLUFS, gain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        duration = try c.decode(CMTime.self, forKey: .duration)
        naturalSize = CGSize(
            width: try c.decode(Double.self, forKey: .width),
            height: try c.decode(Double.self, forKey: .height)
        )
        let t = try c.decode([Double].self, forKey: .transform)
        preferredTransform = t.count == 6
            ? CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
            : .identity
        nominalFrameRate = try c.decodeIfPresent(Double.self, forKey: .nominalFrameRate) ?? 30
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        integratedLUFS = try c.decodeIfPresent(Double.self, forKey: .integratedLUFS)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try c.encode(duration, forKey: .duration)
        try c.encode(Double(naturalSize.width), forKey: .width)
        try c.encode(Double(naturalSize.height), forKey: .height)
        let t = preferredTransform
        try c.encode([t.a, t.b, t.c, t.d, t.tx, t.ty].map(Double.init), forKey: .transform)
        try c.encode(nominalFrameRate, forKey: .nominalFrameRate)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encodeIfPresent(integratedLUFS, forKey: .integratedLUFS)
        try c.encode(gain, forKey: .gain)
    }
}
