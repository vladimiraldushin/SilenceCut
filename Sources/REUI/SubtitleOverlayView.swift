import SwiftUI
import RECore
import CoreMedia

/// Real-time subtitle overlay on video preview with karaoke word-by-word highlighting.
/// Renders as SwiftUI overlay synced with playhead, matching исследование.md approach:
/// "Preview (в реальном времени): SwiftUI Text overlay, синхронизированный с playhead"
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
        // Scale factor: map 1080×1920 canvas → actual preview size
        let scale = min(size.width / 1080, size.height / 1920)
        let fontSize = style.fontSize * scale
        let yPos = style.position.yCenter * scale

        let words = splitIntoLines(entry.words, maxPerLine: style.maxWordsPerLine)

        VStack(spacing: 2 * scale) {
            ForEach(Array(words.enumerated()), id: \.offset) { lineIdx, lineWords in
                lineView(words: lineWords, fontSize: fontSize, scale: scale)
            }
        }
        .position(x: size.width / 2, y: yPos)
    }

    @ViewBuilder
    private func lineView(words: [WordTiming], fontSize: CGFloat, scale: CGFloat) -> some View {
        let hasBackground = style.backgroundOpacity > 0.01

        HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.element.id) { idx, word in
                wordView(word: word, fontSize: fontSize, scale: scale)
            }
        }
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
    }

    @ViewBuilder
    private func wordView(word: WordTiming, fontSize: CGFloat, scale: CGFloat) -> some View {
        let isActive = isWordActive(word)
        let displayText = style.isUppercase ? word.word.uppercased() : word.word

        Text(displayText + " ")
            .font(.custom(style.fontName, size: fontSize))
            .foregroundColor(wordColor(isActive: isActive))
            .scaleEffect(isActive && style.preset == .capcut ? 1.15 : 1.0)
            .shadow(color: .black.opacity(0.8), radius: isActive ? 3 : 1, x: 0, y: 1)
            .animation(.easeInOut(duration: 0.08), value: isActive)
    }

    // MARK: - Helpers

    private func isWordActive(_ word: WordTiming) -> Bool {
        guard let entry = entry, let idx = activeWordIndex else { return false }
        guard let wordIdx = entry.words.firstIndex(where: { $0.id == word.id }) else { return false }
        return wordIdx == idx
    }

    private func wordColor(isActive: Bool) -> Color {
        let c = isActive ? style.highlightColor : style.textColor
        return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    /// Split words into lines of maxPerLine each
    private func splitIntoLines(_ words: [WordTiming], maxPerLine: Int) -> [[WordTiming]] {
        guard maxPerLine > 0 else { return [words] }
        var lines: [[WordTiming]] = []
        var current: [WordTiming] = []
        for word in words {
            current.append(word)
            if current.count >= maxPerLine {
                lines.append(current)
                current = []
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
