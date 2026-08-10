import SwiftUI
import CoreGraphics
import RECore

#if os(macOS)

/// Рамка кадрирования поверх превью: тянешь — двигаешь кадр, скроллишь — меняешь масштаб.
///
/// Работает с выделенным клипом хребта или перебивкой. Сдвиг хранится в долях холста,
/// поэтому жест переводится в те же единицы: результат не зависит от размера окна.
public struct FramingOverlayView: View {
    @Bindable var viewModel: EditorViewModel

    @State private var dragStartOffset: CGPoint?

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geo in
            if let framing = viewModel.selectedFraming {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(in: geo.size, framing: framing))

                    frameOutline(framing: framing, in: geo.size)
                    hint
                }
                .onContinuousHover { phase in
                    if case .ended = phase { viewModel.framingEnded() }
                }
                // Скролл над превью меняет масштаб кадра выделенного элемента
                .onScrollWheel { delta in
                    var updated = framing
                    updated.scale = max(0.2, min(4.0, updated.scale * (1 + delta * 0.002)))
                    viewModel.setSelectedFraming(updated)
                }
            }
        }
    }

    private func dragGesture(in size: CGSize, framing: ClipFraming) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartOffset == nil { dragStartOffset = framing.offset }
                guard let start = dragStartOffset, size.width > 0, size.height > 0 else { return }
                var updated = framing
                updated.offset = CGPoint(
                    x: start.x + value.translation.width / size.width,
                    y: start.y - value.translation.height / size.height  // видеокадр считает Y снизу
                )
                viewModel.setSelectedFraming(updated)
            }
            .onEnded { _ in
                dragStartOffset = nil
                viewModel.framingEnded()
            }
    }

    /// Контур того, что реально попадёт в кадр — при масштабе меньше единицы виден и он сам,
    /// и чёрные поля вокруг
    private func frameOutline(framing: ClipFraming, in size: CGSize) -> some View {
        let width = size.width * framing.scale
        let height = size.height * framing.scale
        let x = (size.width - width) / 2 + framing.offset.x * size.width
        let y = (size.height - height) / 2 - framing.offset.y * size.height

        return Rectangle()
            .strokeBorder(Color.yellow.opacity(0.9), lineWidth: 1.5)
            .frame(width: max(4, width), height: max(4, height))
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    private var hint: some View {
        Text("Тяните кадр · Колесо — масштаб")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
            .allowsHitTesting(false)
    }
}

// MARK: - Колесо мыши в SwiftUI

private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            onScroll?(Double(event.scrollingDeltaY))
        }
        // Ловим только колесо: клики и перетаскивание должны доставаться жестам SwiftUI
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private extension View {
    func onScrollWheel(_ action: @escaping (Double) -> Void) -> some View {
        background(ScrollWheelCatcher(onScroll: action))
    }
}

#endif
