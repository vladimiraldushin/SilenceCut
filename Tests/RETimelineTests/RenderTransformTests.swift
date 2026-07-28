import Testing
import CoreGraphics
@testable import RETimeline
import RECore

// Вертикальный кадр 1080×1920 без поворота — базовый случай
private let vertical = CGSize(width: 1080, height: 1920)
private let horizontal = CGSize(width: 1920, height: 1080)

@Test func sourceAspectWithoutZoomIsIdentity() {
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical, zoom: 1.0
    )
    #expect(abs(t.a - 1) < 0.0001)
    #expect(abs(t.d - 1) < 0.0001)
    #expect(abs(t.tx) < 0.0001)
    #expect(abs(t.ty) < 0.0001)
}

@Test func zoomScalesAboutCenter() {
    let zoom = 1.10
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical, zoom: zoom
    )
    #expect(abs(t.a - CGFloat(zoom)) < 0.0001)

    // Центр кадра остаётся на месте — зум идёт от центра, а не от угла
    let center = CGPoint(x: vertical.width / 2, y: vertical.height / 2)
    let moved = center.applying(t)
    #expect(abs(moved.x - center.x) < 0.01)
    #expect(abs(moved.y - center.y) < 0.01)
}

@Test func horizontalSourceFillsVerticalTarget() {
    // 16:9 → 9:16: масштаб по ширине (1080/1920 = 0.5625 мало), нужен fill по высоте
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: horizontal, targetSize: vertical, zoom: 1.0
    )
    let expectedScale = vertical.height / horizontal.height  // 1920/1080 = 1.777…
    #expect(abs(t.a - expectedScale) < 0.0001)

    // Кадр заполняет цель целиком (без чёрных полей) и обрезан симметрично
    let scaledWidth = horizontal.width * expectedScale
    #expect(scaledWidth >= vertical.width)
    #expect(abs(t.tx - (vertical.width - scaledWidth) / 2) < 0.01)
    #expect(abs(t.ty) < 0.01)
}

@Test func verticalSourceFillsSquareTarget() {
    let square = CGSize(width: 1080, height: 1080)
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: square, zoom: 1.0
    )
    // 1080×1920 → 1080×1080: масштаб 1.0 по ширине, по высоте обрезаем поровну сверху и снизу
    #expect(abs(t.a - 1.0) < 0.0001)
    #expect(abs(t.ty - (square.height - vertical.height) / 2) < 0.01)
}

@Test func rotatedSourceKeepsOrientationTransform() {
    // preferredTransform iPhone-портрета: поворот на 90° со сдвигом в положительную четверть
    let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    let t = CompositionBuilder.renderTransform(
        sourceTransform: rotate90, orientedSize: vertical, targetSize: vertical, zoom: 1.0
    )
    // Углы натурального кадра 1920×1080 должны лечь ровно в 1080×1920
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0),
                   CGPoint(x: 0, y: 1080), CGPoint(x: 1920, y: 1080)].map { $0.applying(t) }
    let xs = corners.map(\.x), ys = corners.map(\.y)
    #expect(abs(xs.min()! - 0) < 0.01)
    #expect(abs(xs.max()! - 1080) < 0.01)
    #expect(abs(ys.min()! - 0) < 0.01)
    #expect(abs(ys.max()! - 1920) < 0.01)
}

@Test func jumpCutZoomAlternatesBetweenClips() {
    var options = RenderOptions()
    options.jumpCutZoomEnabled = true
    options.jumpCutZoomAmount = 1.08

    #expect(options.zoomScale(forClipIndex: 0) == 1.0)
    #expect(options.zoomScale(forClipIndex: 1) == 1.08)
    #expect(options.zoomScale(forClipIndex: 2) == 1.0)
    #expect(options.zoomScale(forClipIndex: 3) == 1.08)
}

@Test func jumpCutZoomDisabledKeepsScaleOne() {
    let options = RenderOptions()
    #expect(options.jumpCutZoomEnabled == false)
    #expect(options.zoomScale(forClipIndex: 1) == 1.0)
}
