import Testing
import Foundation
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

// Джамп-кат зум: чередование с минимальным временем удержания 1.5 с
private var zoomOptions: RenderOptions {
    RenderOptions(jumpCutZoomEnabled: true, jumpCutZoomAmount: 1.08, jumpCutZoomMinHold: 1.5)
}

@Test func jumpCutZoomAlternatesOnLongClips() {
    // Каждый кусок длиннее порога — масштаб меняется на каждой склейке, как и задумано
    let scales = zoomOptions.zoomScales(forClipDurations: [5, 5, 5, 5])
    #expect(scales == [1.0, 1.08, 1.0, 1.08])
}

@Test func jumpCutZoomHoldsThroughShortClips() {
    // Серия коротких кусков (вырезанные паузы в речи) — масштаб держится, кадр не дёргается
    let scales = zoomOptions.zoomScales(forClipDurations: [5, 0.3, 0.4, 0.3, 5])
    #expect(scales == [1.0, 1.08, 1.08, 1.08, 1.08])

    let changes = zip(scales, scales.dropFirst()).filter { $0 != $1 }.count
    #expect(changes == 1)
}

@Test func jumpCutZoomRareOnAllShortClips() {
    // Весь ролик из коротких кусков: зум остаётся, но переключается редко
    let durations = [Double](repeating: 0.4, count: 20)
    let scales = zoomOptions.zoomScales(forClipDurations: durations)
    let changes = zip(scales, scales.dropFirst()).filter { $0 != $1 }.count

    // 20 × 0.4 с = 8 с; при удержании 1.5 с это не больше 5 смен вместо 19
    #expect(changes <= 5)
    #expect(changes >= 1)
}

@Test func jumpCutZoomKeepsMinimumHoldBetweenChanges() {
    // Ключевое свойство: между сменами масштаба всегда проходит не меньше заданного времени
    let durations: [Double] = [3.0, 0.2, 0.9, 0.4, 2.5, 0.3, 0.3, 4.0, 0.6]
    let options = zoomOptions
    let scales = options.zoomScales(forClipDurations: durations)

    var secondsSinceChange = durations[0]
    for i in 1..<scales.count {
        if scales[i] != scales[i - 1] {
            #expect(secondsSinceChange >= options.jumpCutZoomMinHold - 0.001)
            secondsSinceChange = durations[i]
        } else {
            secondsSinceChange += durations[i]
        }
    }
}

@Test func jumpCutZoomStartsWithoutZoom() {
    // Первый кусок всегда в исходном масштабе — иначе ролик начинался бы с наезда
    let scales = zoomOptions.zoomScales(forClipDurations: [5, 5])
    #expect(scales.first == 1.0)
}

@Test func jumpCutZoomDisabledKeepsScaleOne() {
    let options = RenderOptions()
    #expect(options.jumpCutZoomEnabled == false)
    #expect(options.zoomScales(forClipDurations: [5, 5, 5]) == [1.0, 1.0, 1.0])
}

@Test func renderOptionsDecodeWithoutNewFields() throws {
    // Проекты, сохранённые до появления удержания масштаба, должны читаться
    let legacy = """
    {"outputAspect":"vertical","jumpCutZoomEnabled":true,"jumpCutZoomAmount":1.1,"audioGain":1.4}
    """
    let options = try JSONDecoder().decode(RenderOptions.self, from: Data(legacy.utf8))

    #expect(options.outputAspect == .vertical)
    #expect(options.jumpCutZoomEnabled)
    #expect(options.jumpCutZoomAmount == 1.1)
    #expect(options.jumpCutZoomMinHold == 1.5)   // значение по умолчанию
    #expect(options.audioGain == 1.4)
}
