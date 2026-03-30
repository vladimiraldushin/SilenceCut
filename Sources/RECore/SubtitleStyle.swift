import Foundation
import CoreGraphics

/// Style preset for subtitles
public enum SubtitlePreset: String, Codable, CaseIterable, Identifiable {
    case classic    // White on semi-transparent black pill
    case capcut     // Bold, colored word-by-word highlight
    case hormozi    // Uppercase, green highlight on active word
    case script     // Serif, italic+glow on active word

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .capcut: return "CapCut"
        case .hormozi: return "Hormozi"
        case .script: return "Script"
        }
    }
}

/// How the active word is highlighted
public enum HighlightMode: String, Codable, CaseIterable {
    case color      // Change foreground color (default)
    case glow      // White glow on active word, inactive dimmed
}

/// Vertical position for subtitles (in 1080×1920 canvas)
public enum SubtitlePosition: String, Codable, CaseIterable {
    case top
    case center
    case bottom

    /// Y center in 1080×1920 canvas, respecting safe zones
    /// Instagram: bottom 320px, TikTok: bottom 480px
    /// Safe subtitle range: y 1000-1300 (above ALL platform controls)
    public var yCenter: CGFloat {
        switch self {
        case .top: return 320       // below top safe zone (220px)
        case .center: return 960    // true center
        case .bottom: return 1100   // y ~1100: safely above Instagram (1600) and TikTok (1440) controls
        }
    }
}

/// Safe zones for social media platforms (1080×1920 canvas)
/// Based on actual platform measurements:
///   Instagram Reels: top 220, bottom 420, left 35, right 170
///   TikTok:          top 180, bottom 320, left 60, right 120
///   YouTube Shorts:  top 140, bottom 270, left 70, right 190
/// Universal = worst case from all three
public struct SafeZone {
    // Universal (worst case across all platforms)
    public static let top: CGFloat = 220        // Instagram worst
    public static let bottom: CGFloat = 420     // Instagram worst (from bottom edge)
    public static let left: CGFloat = 70        // YouTube worst
    public static let right: CGFloat = 190      // YouTube worst
    public static let safeTop: CGFloat = 220
    public static let safeBottom: CGFloat = 1500  // 1920 - 420

    // Per-platform
    public struct Instagram {
        public static let top: CGFloat = 220
        public static let bottom: CGFloat = 420
        public static let left: CGFloat = 35
        public static let right: CGFloat = 170
    }
    public struct TikTok {
        public static let top: CGFloat = 180
        public static let bottom: CGFloat = 320
        public static let left: CGFloat = 60
        public static let right: CGFloat = 120
    }
    public struct YouTubeShorts {
        public static let top: CGFloat = 140
        public static let bottom: CGFloat = 270
        public static let left: CGFloat = 70
        public static let right: CGFloat = 190
    }
}

/// RGBA color that's Codable
public struct CodableColor: Codable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = CodableColor(red: 1, green: 1, blue: 1)
    public static let black = CodableColor(red: 0, green: 0, blue: 0)
    public static let yellow = CodableColor(red: 1, green: 0.9, blue: 0)
    public static let green = CodableColor(red: 0, green: 1, blue: 0)
    public static let cyan = CodableColor(red: 0, green: 0.9, blue: 1)
    public static let orange = CodableColor(red: 1, green: 0.6, blue: 0)
    public static let pink = CodableColor(red: 1, green: 0.3, blue: 0.5)
    public static let red = CodableColor(red: 1, green: 0.2, blue: 0.2)

    /// Predefined highlight colors for karaoke picker
    public static let highlightPresets: [(name: String, color: CodableColor)] = [
        ("Жёлтый", .yellow),
        ("Зелёный", .green),
        ("Голубой", .cyan),
        ("Оранжевый", .orange),
        ("Розовый", .pink),
        ("Красный", .red),
        ("Белый", .white),
    ]
}

/// Full subtitle styling configuration
public enum SubtitleBackgroundShape: String, Codable, CaseIterable {
    case rectangle
    case oval
}

public struct SubtitleStyle: Codable, Equatable {
    public var preset: SubtitlePreset
    public var fontName: String
    public var fontSize: CGFloat          // in canvas pixels (1080×1920)
    public var textColor: CodableColor
    public var highlightColor: CodableColor
    public var backgroundColor: CodableColor
    public var backgroundOpacity: CGFloat
    public var backgroundBlurRadius: CGFloat  // 0 = sharp edges, 10-40 = smooth feathered gradient
    public var backgroundPaddingH: CGFloat    // horizontal padding in canvas pixels
    public var backgroundPaddingV: CGFloat    // vertical padding in canvas pixels
    public var backgroundShape: SubtitleBackgroundShape
    public var position: SubtitlePosition
    public var customYCenter: CGFloat?    // nil = use position.yCenter, set = override
    public var highlightMode: HighlightMode
    public var italicFontName: String?   // used when highlightMode == .glow
    public var isUppercase: Bool
    public var maxWordsPerLine: Int

    /// Effective Y center — uses customYCenter if set, otherwise position preset
    public var effectiveYCenter: CGFloat {
        customYCenter ?? position.yCenter
    }

    public init(
        preset: SubtitlePreset = .classic,
        fontName: String = "Helvetica-Bold",
        fontSize: CGFloat = 48,
        textColor: CodableColor = .white,
        highlightColor: CodableColor = .yellow,
        backgroundColor: CodableColor = .black,
        backgroundOpacity: CGFloat = 0.7,
        backgroundBlurRadius: CGFloat = 0,
        backgroundPaddingH: CGFloat = 24,
        backgroundPaddingV: CGFloat = 12,
        backgroundShape: SubtitleBackgroundShape = .rectangle,
        position: SubtitlePosition = .bottom,
        customYCenter: CGFloat? = nil,
        highlightMode: HighlightMode = .color,
        italicFontName: String? = nil,
        isUppercase: Bool = false,
        maxWordsPerLine: Int = 6
    ) {
        self.preset = preset
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.highlightColor = highlightColor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlurRadius = backgroundBlurRadius
        self.backgroundPaddingH = backgroundPaddingH
        self.backgroundPaddingV = backgroundPaddingV
        self.backgroundShape = backgroundShape
        self.position = position
        self.customYCenter = customYCenter
        self.highlightMode = highlightMode
        self.italicFontName = italicFontName
        self.isUppercase = isUppercase
        self.maxWordsPerLine = maxWordsPerLine
    }

    // MARK: - Presets

    public static let classic = SubtitleStyle(
        preset: .classic,
        fontName: "Helvetica-Bold",
        fontSize: 48,
        textColor: .white,
        highlightColor: .yellow,
        backgroundColor: .black,
        backgroundOpacity: 0.7,
        backgroundBlurRadius: 20,
        position: .bottom,
        isUppercase: false,
        maxWordsPerLine: 6
    )

    public static let capcut = SubtitleStyle(
        preset: .capcut,
        fontName: "Avenir-Black",
        fontSize: 56,
        textColor: .white,
        highlightColor: .yellow,
        backgroundColor: .black,
        backgroundOpacity: 0,
        backgroundBlurRadius: 0,
        position: .center,
        isUppercase: false,
        maxWordsPerLine: 3
    )

    public static let hormozi = SubtitleStyle(
        preset: .hormozi,
        fontName: "Impact",
        fontSize: 52,
        textColor: .white,
        highlightColor: .green,
        backgroundColor: .black,
        backgroundOpacity: 0,
        backgroundBlurRadius: 0,
        position: .bottom,
        isUppercase: true,
        maxWordsPerLine: 4
    )

    public static let script = SubtitleStyle(
        preset: .script,
        fontName: "Baskerville-Bold",
        fontSize: 54,
        textColor: .white,
        highlightColor: .white,
        backgroundColor: CodableColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
        backgroundOpacity: 0.85,
        backgroundBlurRadius: 0,
        backgroundPaddingH: 40,
        backgroundPaddingV: 24,
        backgroundShape: .rectangle,
        position: .center,
        highlightMode: .glow,
        italicFontName: "Baskerville-BoldItalic",
        isUppercase: false,
        maxWordsPerLine: 5
    )

    /// Get preset style by type
    public static func forPreset(_ preset: SubtitlePreset) -> SubtitleStyle {
        switch preset {
        case .classic: return .classic
        case .capcut: return .capcut
        case .hormozi: return .hormozi
        case .script: return .script
        }
    }
}
