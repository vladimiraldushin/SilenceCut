import Foundation
import CoreGraphics

/// Формат кадра на выходе. `.source` — как в исходнике (поведение по умолчанию),
/// остальные кропят по центру под стандартные размеры соцсетей.
public enum OutputAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case source
    case vertical      // 9:16 — Reels, Shorts, TikTok
    case square        // 1:1 — лента
    case horizontal    // 16:9 — YouTube

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .source: return "Исходный"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .horizontal: return "16:9"
        }
    }

    /// Размер кадра на выходе; nil — брать размер исходника
    public var renderSize: CGSize? {
        switch self {
        case .source: return nil
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .horizontal: return CGSize(width: 1920, height: 1080)
        }
    }

    /// Соотношение сторон для превью (nil — как у исходника)
    public var ratio: CGFloat? {
        guard let size = renderSize else { return nil }
        return size.width / size.height
    }
}

/// Настройки рендера — применяются и в превью, и в экспорте (одна точка: CompositionBuilder)
public struct RenderOptions: Codable, Equatable, Sendable {
    /// Формат кадра с центральным кропом
    public var outputAspect: OutputAspect

    /// Джамп-кат зум: чередование масштаба на склейках — приём talking-head роликов,
    /// маскирует стыки после вырезания пауз
    public var jumpCutZoomEnabled: Bool
    public var jumpCutZoomAmount: Double

    /// Минимальное время между сменами масштаба, секунды. После вырезания пауз идут
    /// серии коротких кусков; без этого порога кадр дёргался бы на каждом стыке.
    public var jumpCutZoomMinHold: Double

    /// Линейный множитель громкости (1.0 — без изменений). Считается из замера LUFS.
    public var audioGain: Double

    public init(
        outputAspect: OutputAspect = .source,
        jumpCutZoomEnabled: Bool = false,
        jumpCutZoomAmount: Double = 1.08,
        jumpCutZoomMinHold: Double = 1.5,
        audioGain: Double = 1.0
    ) {
        self.outputAspect = outputAspect
        self.jumpCutZoomEnabled = jumpCutZoomEnabled
        self.jumpCutZoomAmount = jumpCutZoomAmount
        self.jumpCutZoomMinHold = jumpCutZoomMinHold
        self.audioGain = audioGain
    }

    public static let `default` = RenderOptions()

    /// Масштабы для всех клипов таймлайна по их длительностям.
    /// Масштаб чередуется, но переключается только на тех стыках, где предыдущий
    /// уровень продержался на экране не меньше `jumpCutZoomMinHold`. Серия коротких
    /// кусков проходит на одном масштабе — кадр стоит, а не прыгает.
    public func zoomScales(forClipDurations durations: [Double]) -> [Double] {
        guard jumpCutZoomEnabled else {
            return Array(repeating: 1.0, count: durations.count)
        }

        var scales: [Double] = []
        scales.reserveCapacity(durations.count)
        var zoomedIn = false
        var heldSeconds = 0.0

        for (index, duration) in durations.enumerated() {
            if index > 0 && heldSeconds >= jumpCutZoomMinHold {
                zoomedIn.toggle()
                heldSeconds = 0
            }
            scales.append(zoomedIn ? jumpCutZoomAmount : 1.0)
            heldSeconds += max(0, duration)
        }
        return scales
    }

    // Старые проекты сохранены без новых полей — читаем с подстановкой значений по умолчанию,
    // иначе восстановление проекта молча провалится
    private enum CodingKeys: String, CodingKey {
        case outputAspect, jumpCutZoomEnabled, jumpCutZoomAmount, jumpCutZoomMinHold, audioGain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputAspect = try c.decodeIfPresent(OutputAspect.self, forKey: .outputAspect) ?? .source
        jumpCutZoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .jumpCutZoomEnabled) ?? false
        jumpCutZoomAmount = try c.decodeIfPresent(Double.self, forKey: .jumpCutZoomAmount) ?? 1.08
        jumpCutZoomMinHold = try c.decodeIfPresent(Double.self, forKey: .jumpCutZoomMinHold) ?? 1.5
        audioGain = try c.decodeIfPresent(Double.self, forKey: .audioGain) ?? 1.0
    }
}
