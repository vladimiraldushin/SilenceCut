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

    /// Джамп-кат зум: чередование масштаба на соседних клипах — приём talking-head роликов,
    /// маскирует склейки после вырезания пауз
    public var jumpCutZoomEnabled: Bool
    public var jumpCutZoomAmount: Double

    /// Линейный множитель громкости (1.0 — без изменений). Считается из замера LUFS.
    public var audioGain: Double

    public init(
        outputAspect: OutputAspect = .source,
        jumpCutZoomEnabled: Bool = false,
        jumpCutZoomAmount: Double = 1.08,
        audioGain: Double = 1.0
    ) {
        self.outputAspect = outputAspect
        self.jumpCutZoomEnabled = jumpCutZoomEnabled
        self.jumpCutZoomAmount = jumpCutZoomAmount
        self.audioGain = audioGain
    }

    public static let `default` = RenderOptions()

    /// Масштаб для клипа по его порядковому номеру среди включённых
    public func zoomScale(forClipIndex index: Int) -> Double {
        guard jumpCutZoomEnabled else { return 1.0 }
        return index % 2 == 1 ? jumpCutZoomAmount : 1.0
    }
}
