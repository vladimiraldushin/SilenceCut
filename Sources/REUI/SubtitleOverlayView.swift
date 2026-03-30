import SwiftUI
import RECore
import CoreMedia

/// Real-time subtitle overlay using AttributedString for proper word wrapping.
/// Active word highlighted via karaoke effect. SwiftUI handles line breaks
/// at word boundaries — never mid-word.
public struct SubtitleOverlayView: View {
    let entry: SubtitleEntry?
    let activeWordIndex: Int?
    let style: SubtitleStyle
    let videoFrame: CGSize
    var showSafeZones: Bool = false

    public init(entry: SubtitleEntry?, activeWordIndex: Int?, style: SubtitleStyle, videoFrame: CGSize, showSafeZones: Bool = false) {
        self.entry = entry
        self.activeWordIndex = activeWordIndex
        self.style = style
        self.videoFrame = videoFrame
        self.showSafeZones = showSafeZones
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if showSafeZones {
                    safeZoneOverlay(size: geo.size)
                }
                if let entry = entry, !entry.words.isEmpty {
                    subtitleContent(entry: entry, size: geo.size)
                }
            }
        }
    }

    @ViewBuilder
    private func safeZoneOverlay(size: CGSize) -> some View {
        let scale = min(size.width / 1080, size.height / 1920)
        let topH = SafeZone.top * scale
        let bottomH = SafeZone.bottom * scale
        let leftW = SafeZone.left * scale
        let rightW = SafeZone.right * scale

        // Top zone
        Rectangle()
            .fill(Color.red.opacity(0.15))
            .frame(width: size.width, height: topH)
            .position(x: size.width / 2, y: topH / 2)
        // Bottom zone
        Rectangle()
            .fill(Color.red.opacity(0.15))
            .frame(width: size.width, height: bottomH)
            .position(x: size.width / 2, y: size.height - bottomH / 2)
        // Left zone
        Rectangle()
            .fill(Color.orange.opacity(0.1))
            .frame(width: leftW, height: size.height - topH - bottomH)
            .position(x: leftW / 2, y: size.height / 2)
        // Right zone
        Rectangle()
            .fill(Color.orange.opacity(0.1))
            .frame(width: rightW, height: size.height - topH - bottomH)
            .position(x: size.width - rightW / 2, y: size.height / 2)
        // Labels
        Text("Safe Zone")
            .font(.system(size: 10 * scale))
            .foregroundColor(.red.opacity(0.5))
            .position(x: size.width / 2, y: topH + 10 * scale)
    }

    @ViewBuilder
    private func subtitleContent(entry: SubtitleEntry, size: CGSize) -> some View {
        let scale = min(size.width / 1080, size.height / 1920)
        let fontSize = style.fontSize * scale
        let yPos = style.effectiveYCenter * scale
        let hasBackground = style.backgroundOpacity > 0.01
        let maxWidth = size.width - (SafeZone.left + SafeZone.right) * scale

        let padH = hasBackground ? style.backgroundPaddingH * scale : 0
        let padV = hasBackground ? style.backgroundPaddingV * scale : 0

        let useGlow = style.highlightMode == .glow && activeWordIndex != nil

        ZStack {
            // Main text layer
            Text(buildAttributedString(entry: entry, fontSize: fontSize))
                .multilineTextAlignment(.center)
                .lineSpacing(4 * scale)
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, padH)
                .padding(.vertical, padV)
                .background(
                    hasBackground ?
                        subtitleBackground(scale: scale)
                        : nil
                )
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)

            // Glow layer — only active word rendered, blurred for glow effect
            if useGlow {
                Text(buildGlowAttributedString(entry: entry, fontSize: fontSize))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4 * scale)
                    .frame(maxWidth: maxWidth)
                    .padding(.horizontal, padH)
                    .padding(.vertical, padV)
                    .blur(radius: 6 * scale)

                // Second brighter pass for intense center glow
                Text(buildGlowAttributedString(entry: entry, fontSize: fontSize))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4 * scale)
                    .frame(maxWidth: maxWidth)
                    .padding(.horizontal, padH)
                    .padding(.vertical, padV)
                    .blur(radius: 2 * scale)
            }
        }
        .position(x: size.width / 2, y: yPos)
    }

    /// Background behind subtitles
    @ViewBuilder
    private func subtitleBackground(scale: CGFloat) -> some View {
        let bgColor = Color(
            red: style.backgroundColor.red,
            green: style.backgroundColor.green,
            blue: style.backgroundColor.blue,
            opacity: style.backgroundOpacity
        )
        let blur = style.backgroundBlurRadius * scale
        let cornerRadius = 8 * scale

        Group {
            switch style.backgroundShape {
            case .rectangle:
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(bgColor)
            case .oval:
                Capsule()
                    .fill(bgColor)
            }
        }
        .blur(radius: blur > 1 ? blur : 0)
    }

    /// Build a single AttributedString with karaoke highlighting on the active word
    private func buildAttributedString(entry: SubtitleEntry, fontSize: CGFloat) -> AttributedString {
        let textColor = swiftUIColor(style.textColor)
        let highlightColor = swiftUIColor(style.highlightColor)
        let font = Font.custom(style.fontName, size: fontSize)

        var result = AttributedString()

        for (idx, word) in entry.words.enumerated() {
            let isActive = idx == activeWordIndex
            let displayWord = style.isUppercase ? word.word.uppercased() : word.word
            let text = idx > 0 ? " \(displayWord)" : displayWord

            var attr = AttributedString(text)
            attr.font = font

            switch style.highlightMode {
            case .color:
                attr.foregroundColor = isActive ? highlightColor : textColor
            case .glow:
                // Glow mode: active word is brighter, inactive is dimmed
                attr.foregroundColor = isActive ? .white : textColor.opacity(0.5)
            }

            result.append(attr)
        }

        return result
    }

    /// Build attributed string for the glow layer (only the active word visible)
    private func buildGlowAttributedString(entry: SubtitleEntry, fontSize: CGFloat) -> AttributedString {
        let font = Font.custom(style.fontName, size: fontSize)

        var result = AttributedString()

        for (idx, word) in entry.words.enumerated() {
            let isActive = idx == activeWordIndex
            let displayWord = style.isUppercase ? word.word.uppercased() : word.word
            let text = idx > 0 ? " \(displayWord)" : displayWord

            var attr = AttributedString(text)
            attr.font = font
            // Only active word glows — rest is transparent
            attr.foregroundColor = isActive ? .white : .clear

            result.append(attr)
        }

        return result
    }

    private func swiftUIColor(_ c: CodableColor) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
