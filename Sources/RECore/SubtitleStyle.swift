import Foundation
import CoreGraphics

/// Style preset for subtitles
public enum SubtitlePreset: String, Codable, CaseIterable, Identifiable {
    case classic    // White on semi-transparent black pill
    case capcut     // Bold, colored word-by-word highlight
    case hormozi    // Uppercase, green highlight on active word

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .capcut: return "CapCut"
        case .hormozi: return "Hormozi"
        }
    }
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
}

/// Full subtitle styling configuration
public struct SubtitleStyle: Codable, Equatable {
    public var preset: SubtitlePreset
    public var fontName: String
    public var fontSize: CGFloat          // in canvas pixels (1080×1920)
    public var textColor: CodableColor
    public var highlightColor: CodableColor
    public var backgroundColor: CodableColor
    public var backgroundOpacity: CGFloat
    public var position: SubtitlePosition
    public var customYCenter: CGFloat?    // nil = use position.yCenter, set = override
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
        position: SubtitlePosition = .bottom,
        customYCenter: CGFloat? = nil,
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
        self.position = position
        self.customYCenter = customYCenter
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
        position: .bottom,
        isUppercase: true,
        maxWordsPerLine: 4
    )

    /// Get preset style by type
    public static func forPreset(_ preset: SubtitlePreset) -> SubtitleStyle {
        switch preset {
        case .classic: return .classic
        case .capcut: return .capcut
        case .hormozi: return .hormozi
        }
    }
}
