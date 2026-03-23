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

    public init(entry: SubtitleEntry?, activeWordIndex: Int?, style: SubtitleStyle, videoFrame: CGSize) {
        self.entry = entry
        self.activeWordIndex = activeWordIndex
        self.style = style
        self.videoFrame = videoFrame
    }

    public var body: some View {
        GeometryReader { geo in
            if let entry = entry, !entry.words.isEmpty {
                subtitleContent(entry: entry, size: geo.size)
            }
        }
    }

    @ViewBuilder
    private func subtitleContent(entry: SubtitleEntry, size: CGSize) -> some View {
        let scale = min(size.width / 1080, size.height / 1920)
        let fontSize = style.fontSize * scale
        let yPos = style.position.yCenter * scale
        let hasBackground = style.backgroundOpacity > 0.01
        let maxWidth = size.width - (SafeZone.left + SafeZone.right) * scale

        Text(buildAttributedString(entry: entry, fontSize: fontSize))
            .multilineTextAlignment(.center)
            .lineSpacing(4 * scale)
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, hasBackground ? 12 * scale : 0)
            .padding(.vertical, hasBackground ? 6 * scale : 0)
            .background(
                hasBackground ?
                    RoundedRectangle(cornerRadius: 8 * scale)
                        .fill(Color(
                            red: style.backgroundColor.red,
                            green: style.backgroundColor.green,
                            blue: style.backgroundColor.blue,
                            opacity: style.backgroundOpacity
                        ))
                    : nil
            )
            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
            .position(x: size.width / 2, y: yPos)
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
            // Add space between words (not before first)
            let text = idx > 0 ? " \(displayWord)" : displayWord

            var attr = AttributedString(text)
            attr.font = font
            attr.foregroundColor = isActive ? highlightColor : textColor

            result.append(attr)
        }

        return result
    }

    private func swiftUIColor(_ c: CodableColor) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
