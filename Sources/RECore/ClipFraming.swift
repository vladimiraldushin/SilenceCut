import Foundation
import CoreGraphics

/// Кадрирование клипа относительно холста проекта.
///
/// Отсчёт идёт от заполнения холста центральным кропом: `scale == 1` — ровно то поведение,
/// что было до появления разнородных исходников. Больше единицы — приближение, меньше —
/// отдаление с чёрными полями по краям. Отдельного перечисления режимов нет намеренно:
/// «Вписать целиком» — это просто `scale = fitScale / fillScale`, посчитанный кнопкой в UI.
public struct ClipFraming: Codable, Equatable {
    /// Множитель поверх масштаба «заполнить холст»
    public var scale: Double

    /// Сдвиг кадра в долях холста от центра: 0.5 по X уводит на половину ширины вправо
    public var offset: CGPoint

    public static let `default` = ClipFraming(scale: 1.0, offset: .zero)

    public init(scale: Double = 1.0, offset: CGPoint = .zero) {
        self.scale = scale
        self.offset = offset
    }

    // Снимки, сохранённые до появления кадрирования, читаются как значение по умолчанию
    enum CodingKeys: String, CodingKey { case scale, offset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        offset = try c.decodeIfPresent(CGPoint.self, forKey: .offset) ?? .zero
    }

    /// Масштаб, при котором кадр вписывается в холст целиком (с полями), в единицах `scale`.
    /// Используется кнопкой «Вписать целиком»: снаружи не нужно знать, как устроен fill.
    public static func fitScale(orientedSize: CGSize, targetSize: CGSize) -> Double {
        guard orientedSize.width > 0, orientedSize.height > 0 else { return 1.0 }
        let fill = max(targetSize.width / orientedSize.width, targetSize.height / orientedSize.height)
        let fit = min(targetSize.width / orientedSize.width, targetSize.height / orientedSize.height)
        guard fill > 0 else { return 1.0 }
        return Double(fit / fill)
    }
}
