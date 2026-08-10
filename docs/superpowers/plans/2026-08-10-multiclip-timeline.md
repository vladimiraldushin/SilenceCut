# Мультиклиповый таймлайн — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать SilenceCut работу с несколькими разнородными исходниками на одном таймлайне: клипы подряд, перебивки поверх речи, кадрирование на клип, громкость на источник.

**Architecture:** Модель «основа + оверлеи». `EditTimeline` получает реестр `sources: [MediaSource]`, хребет `clips` (видео+звук связаны) и `overlays` (видео без звука). `CompositionBuilder` собирает три дорожки: видео хребта, видео перебивок, звук хребта — и остаётся единственной точкой сборки для превью и экспорта.

**Tech Stack:** Swift 6, SwiftUI + AppKit, AVFoundation, swift-testing (`import Testing`, `@Test`, `#expect`), XcodeGen.

## Global Constraints

- Спека: `docs/superpowers/specs/2026-08-10-multiclip-timeline-design.md`.
- После добавления или удаления файлов в `Sources/` или `Tests/` обязателен `xcodegen generate`, иначе файл не попадёт в таргет.
- Зависимости строго в одну сторону: `RECore` → `RETimeline` / `REAudioAnalysis` → `REExport` → `REUI` → приложения.
- `CompositionBuilder.build(from:options:)` — единственное место сборки `AVComposition`. Превью и экспорт идут только через него.
- Тесты — swift-testing, не XCTest.
- Мультиклиповое редактирование — только macOS. iOS-таргет обязан собираться и открывать мультиклиповые проекты на просмотр и экспорт.
- Комментарии в коде — на русском там, где они объясняют «почему», как в существующем коде.
- Сборка: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug build`
- Тесты: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS'`

---

## Карта файлов

**Создаются:**

| Файл | Ответственность |
|---|---|
| `Sources/RECore/MediaSource.swift` | Описание исходника: URL, bookmark, метаданные, громкость |
| `Sources/RECore/ClipFraming.swift` | Кадрирование клипа: масштаб и сдвиг относительно заполнения холста |
| `Sources/RECore/OverlayClip.swift` | Перебивка: видео без звука на диапазоне таймлайна |
| `Sources/RECore/TimelineRemoval.swift` | Чистая математика риппла: `applyRemovals` и пересчёт времён |
| `Tests/RECoreTests/MediaSourceTests.swift` | Реестр, поиск по id, сериализация |
| `Tests/RECoreTests/TimelineRemovalTests.swift` | Риппл перебивок при вырезании |
| `Tests/RECoreTests/ProjectMigrationTests.swift` | Чтение sidecar v1 |
| `Tests/RETimelineTests/ClipFramingTests.swift` | `renderTransform` с кадрированием |
| `Sources/REUI/SourceShelfView.swift` | Полка источников над таймлайном |
| `Sources/REUI/FramingOverlayView.swift` | Рамка кадрирования поверх превью |

**Изменяются:**

| Файл | Что меняется |
|---|---|
| `Sources/RECore/TimelineClip.swift` | `sourceURL` → `sourceID`, `framing`, шим декодера для v1 |
| `Sources/RECore/EditTimeline.swift` | `sources`, `overlays`, `splitClipBySpeechRanges`, удаление `fromSpeechRanges` |
| `Sources/RECore/Project.swift` | Удаление `sourceURL` / `sourceBookmarkData` |
| `Sources/RECore/ProjectStore.swift` | `version`, миграция v1 → v2 |
| `Sources/RETimeline/CompositionBuilder.swift` | Пер-клиповые трансформации, дорожка перебивок, пустые аудиодиапазоны |
| `Sources/REExport/ExportService.swift` | LPCM 48 кГц на чтении, параметры AAC от проекта |
| `Sources/REUI/EditorViewModel.swift` | Реестр источников, добавление, пер-клиповая детекция, кеши на источник |
| `Sources/REUI/TimelineView.swift` | Две дорожки, дроп, перетаскивание и тяга перебивок (macOS) |
| `Sources/REUI/MainEditorView.swift` | Полка источников, мультивыбор в панели, кадрировщик |
| `Sources/SilenceCutApp/SilenceCutApp.swift` | Мультивыбор в панелях, «Сохранить как…» |

---

## Task 1: Реестр источников и кадрирование в модели

**Files:**
- Create: `Sources/RECore/MediaSource.swift`, `Sources/RECore/ClipFraming.swift`
- Create: `Tests/RECoreTests/MediaSourceTests.swift`
- Modify: `Sources/RECore/TimelineClip.swift`, `Sources/RECore/EditTimeline.swift`
- Modify: `Tests/RECoreTests/TimelineClipTests.swift` (переезд с `sourceURL` на `sourceID`)

**Interfaces:**
- Produces: `MediaSource(id:url:bookmarkData:duration:naturalSize:preferredTransform:nominalFrameRate:hasAudio:integratedLUFS:gain:)`; `EditTimeline.sources: [MediaSource]`; `EditTimeline.source(for: MediaSource.ID) -> MediaSource?`; `TimelineClip.sourceID: MediaSource.ID`; `TimelineClip.framing: ClipFraming`; `ClipFraming(scale:offset:)`, `ClipFraming.default`.

- [ ] **Step 1: Написать падающий тест реестра**

```swift
// Tests/RECoreTests/MediaSourceTests.swift
import Testing
import CoreMedia
import CoreGraphics
@testable import RECore

private func makeSource(_ name: String) -> MediaSource {
    MediaSource(
        url: URL(fileURLWithPath: "/\(name).mp4"),
        duration: CMTime(seconds: 60, preferredTimescale: 600),
        naturalSize: CGSize(width: 1920, height: 1080),
        preferredTransform: .identity,
        nominalFrameRate: 30,
        hasAudio: true
    )
}

@Test func timelineFindsSourceByID() {
    let a = makeSource("a"), b = makeSource("b")
    let timeline = EditTimeline(sources: [a, b], clips: [])
    #expect(timeline.source(for: b.id)?.url.lastPathComponent == "b.mp4")
    #expect(timeline.source(for: UUID()) == nil)
}

@Test func timelineWithTwoSourcesRoundTripsThroughJSON() throws {
    let a = makeSource("a"), b = makeSource("b")
    let clip = TimelineClip(
        sourceID: a.id,
        availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 60, preferredTimescale: 600)),
        sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
    )
    let timeline = EditTimeline(sources: [a, b], clips: [clip])
    let data = try JSONEncoder().encode(timeline)
    let decoded = try JSONDecoder().decode(EditTimeline.self, from: data)
    #expect(decoded.sources.count == 2)
    #expect(decoded.clips.first?.sourceID == a.id)
    #expect(decoded.clips.first?.framing == .default)
}

@Test func defaultFramingIsFullFrame() {
    #expect(ClipFraming.default.scale == 1.0)
    #expect(ClipFraming.default.offset == .zero)
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme RECore -configuration Debug build`
Expected: FAIL — `cannot find 'MediaSource' in scope`.

- [ ] **Step 3: Написать `MediaSource` и `ClipFraming`**

`MediaSource` — `Identifiable, Codable, Equatable, Sendable`, поля по спеке, `gain` по умолчанию 1.0, `integratedLUFS` опционален. `CGSize` и `CGAffineTransform` уже не Codable по умолчанию — добавить `Codable`-расширения рядом с существующими для `CMTime` в `TimelineClip.swift`, либо кодировать `naturalSize` парой `Double` и трансформ шестёркой `Double` внутри самого `MediaSource` (предпочтительно: не засоряет глобальное пространство retroactive-конформансами).

`ClipFraming` — `Codable, Equatable, Sendable`, `scale: Double = 1.0`, `offset: CGPoint = .zero`, статический `default`. Декодер устойчив к отсутствию полей (`decodeIfPresent`), чтобы старые снимки читались.

- [ ] **Step 4: Перевести `TimelineClip` на `sourceID` и добавить `framing`**

Заменить `public let sourceURL: URL` на `public let sourceID: MediaSource.ID`, добавить `public var framing: ClipFraming = .default`. В `init` — те же изменения. Добавить `legacySourceURL: URL?` вне `Codable`-контракта и ручной `init(from:)`: если `sourceID` отсутствует, читать `sourceURL` в `legacySourceURL` и выдать клипу нулевой `sourceID` (`UUID(uuidString: "00000000-0000-0000-0000-000000000000")!`), который Task 3 заменит настоящим.

- [ ] **Step 5: Добавить `sources` в `EditTimeline`**

`public var sources: [MediaSource]` первым полем, `init(sources:clips:)` со значением по умолчанию `[]`, метод `source(for:)`. `splitClip` копирует `sourceID` и `framing` в обе половины.

- [ ] **Step 6: Обновить существующие тесты**

В `Tests/RECoreTests/TimelineClipTests.swift` заменить `sourceURL: URL(fileURLWithPath: "/test.mp4")` на `sourceID: <общий UUID>`.

- [ ] **Step 7: Прогнать тесты**

Run: `xcodegen generate && xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS'`
Expected: PASS для `RECoreTests`. Ошибки компиляции в `RETimeline` / `REUI` ожидаемы — их чинят Task 2 и Task 5; на этом шаге допустимо собирать только схему `RECore`.

- [ ] **Step 8: Коммит**

```bash
git add Sources/RECore Tests/RECoreTests SilenceCut.xcodeproj
git commit -m "feat(core): реестр MediaSource и кадрирование на клип"
```

---

## Task 2: Перебивки и риппл

**Files:**
- Create: `Sources/RECore/OverlayClip.swift`, `Sources/RECore/TimelineRemoval.swift`
- Create: `Tests/RECoreTests/TimelineRemovalTests.swift`
- Modify: `Sources/RECore/EditTimeline.swift`

**Interfaces:**
- Consumes: `MediaSource`, `ClipFraming`, `EditTimeline.sources` (Task 1).
- Produces: `OverlayClip(id:sourceID:sourceRange:timelineStart:framing:isEnabled:)`, `OverlayClip.timelineRange`; `EditTimeline.overlays: [OverlayClip]`; `EditTimeline.applyRemovals(_ removed: [CMTimeRange])`; `EditTimeline.splitClipBySpeechRanges(clipID:speechRanges:)`.

- [ ] **Step 1: Написать падающие тесты риппла**

```swift
// Tests/RECoreTests/TimelineRemovalTests.swift
import Testing
import CoreMedia
@testable import RECore

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
private func range(_ s: Double, _ d: Double) -> CMTimeRange { CMTimeRange(start: t(s), duration: t(d)) }
private let src = UUID()

private func overlay(start: Double, duration: Double) -> OverlayClip {
    OverlayClip(sourceID: src, sourceRange: range(0, duration), timelineStart: t(start))
}

private func timeline(_ overlays: [OverlayClip]) -> EditTimeline {
    var tl = EditTimeline(sources: [], clips: [
        TimelineClip(sourceID: src, availableRange: range(0, 100), sourceRange: range(0, 100))
    ], overlays: overlays)
    tl.recalculateOffsets()
    return tl
}

@Test func overlayAfterRemovalShiftsBack() {
    var tl = timeline([overlay(start: 50, duration: 5)])
    tl.applyRemovals([range(10, 4)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 46) < 0.001)
}

@Test func overlayInsideRemovalDisappears() {
    var tl = timeline([overlay(start: 11, duration: 2)])
    tl.applyRemovals([range(10, 4)])
    #expect(tl.overlays.isEmpty)
}

@Test func overlayOverlappingRemovalEdgeIsTrimmed() {
    // Перебивка 12…18, вырезаем 10…14 — остаётся 4 секунды, приехавшие на 10
    var tl = timeline([overlay(start: 12, duration: 6)])
    tl.applyRemovals([range(10, 4)])
    #expect(tl.overlays.count == 1)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 10) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 4) < 0.001)
    // Обрезали начало — исходный диапазон тоже сдвинулся
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.start) - 2) < 0.001)
}

@Test func overlayBeforeRemovalStaysPut() {
    var tl = timeline([overlay(start: 2, duration: 3)])
    tl.applyRemovals([range(10, 4)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 2) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].sourceRange.duration) - 3) < 0.001)
}

@Test func multipleRemovalsAccumulate() {
    var tl = timeline([overlay(start: 50, duration: 2)])
    tl.applyRemovals([range(5, 3), range(20, 7)])
    #expect(abs(CMTimeGetSeconds(tl.overlays[0].timelineStart) - 40) < 0.001)
}

@Test func splitClipBySpeechRangesKeepsNeighboursIntact() {
    var tl = EditTimeline(sources: [], clips: [
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
        TimelineClip(sourceID: src, availableRange: range(0, 10), sourceRange: range(0, 10)),
    ])
    tl.recalculateOffsets()
    let firstID = tl.clips[0].id
    tl.splitClipBySpeechRanges(clipID: firstID, speechRanges: [range(0, 3), range(7, 3)])
    // Первый клип стал двумя, второй не тронут
    #expect(tl.clips.count == 3)
    #expect(abs(CMTimeGetSeconds(tl.duration) - 16) < 0.001)
    #expect(abs(CMTimeGetSeconds(tl.clips[2].sourceRange.duration) - 10) < 0.001)
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme RECore -configuration Debug build`
Expected: FAIL — `cannot find 'OverlayClip' in scope`.

- [ ] **Step 3: Написать `OverlayClip`**

Поля по спеке; `timelineRange` вычисляется как `CMTimeRange(start: timelineStart, duration: sourceRange.duration)`; `isEnabled` по умолчанию `true`, `framing` — `.default`.

- [ ] **Step 4: Написать `applyRemovals` в `TimelineRemoval.swift`**

Расширение `EditTimeline`. Алгоритм: отсортировать и слить пересекающиеся `removed`; для каждой перебивки посчитать пересечение с объединением; полное покрытие — выбросить; частичное — обрезать `sourceRange` с той стороны, с которой съели, и пересчитать `timelineStart`; затем сдвинуть `timelineStart` назад на суммарную длину вырезанного строго до него. Клипы хребта не трогаются — их правит вызывающий код, `applyRemovals` отвечает только за перебивки и за то, чтобы времена остались согласованными.

- [ ] **Step 5: Написать `splitClipBySpeechRanges`**

Заменяет клип с данным id на набор клипов по диапазонам речи (в координатах исходника этого клипа), сохраняя `sourceID`, `framing`, `speed`. Затем собирает удалённые диапазоны в координатах таймлайна, вызывает `applyRemovals` для перебивок и `recalculateOffsets`.

- [ ] **Step 6: Добавить `overlays` в `EditTimeline`**

`public var overlays: [OverlayClip] = []`, декодируется через `decodeIfPresent` ради старых снимков. Удалить `fromSpeechRanges`.

- [ ] **Step 7: Прогнать тесты**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme RECore -configuration Debug build && xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS' -only-testing:RECoreTests`
Expected: PASS.

- [ ] **Step 8: Коммит**

```bash
git add Sources/RECore Tests/RECoreTests SilenceCut.xcodeproj
git commit -m "feat(core): перебивки и риппл через applyRemovals"
```

---

## Task 3: Миграция проекта v1 → v2

**Files:**
- Modify: `Sources/RECore/ProjectStore.swift`, `Sources/RECore/Project.swift`
- Create: `Tests/RECoreTests/ProjectMigrationTests.swift`

**Interfaces:**
- Consumes: `MediaSource`, `EditTimeline.sources`, `TimelineClip.legacySourceURL` (Task 1).
- Produces: `ProjectSnapshot.version: Int`; `ProjectStore.load(for:)` возвращает снимок с заполненным `timeline.sources`.

- [ ] **Step 1: Написать падающий тест миграции**

```swift
// Tests/RECoreTests/ProjectMigrationTests.swift
import Testing
import Foundation
@testable import RECore

@Test func legacySidecarGetsSynthesizedSource() throws {
    // Sidecar в старом формате: у клипов sourceURL, поля sources и version нет
    let json = """
    {
      "name": "test",
      "savedAt": "2026-01-01T00:00:00Z",
      "subtitleEntries": [],
      "subtitleStyle": \(String(data: try JSONEncoder().encode(SubtitleStyle.classic), encoding: .utf8)!),
      "timeline": {
        "clips": [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "sourceURL": "file:///videos/take1.mp4",
            "availableRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 6000, "timescale": 600}},
            "sourceRange": {"start": {"value": 0, "timescale": 600}, "duration": {"value": 6000, "timescale": 600}},
            "timelineOffset": {"value": 0, "timescale": 600},
            "speed": 1,
            "isEnabled": true
          }
        ]
      }
    }
    """
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let videoURL = dir.appendingPathComponent("take1.mp4")
    try Data(json.utf8).write(to: ProjectStore.sidecarURL(for: videoURL))

    let snapshot = try #require(ProjectStore.load(for: videoURL))
    #expect(snapshot.version == 1)
    #expect(snapshot.timeline.sources.count == 1)
    let source = try #require(snapshot.timeline.sources.first)
    #expect(source.url.lastPathComponent == "take1.mp4")
    #expect(snapshot.timeline.clips.first?.sourceID == source.id)
}

@Test func currentSnapshotRoundTrips() throws {
    let source = MediaSource(
        url: URL(fileURLWithPath: "/videos/a.mp4"),
        duration: CMTime(seconds: 10, preferredTimescale: 600),
        naturalSize: CGSize(width: 1080, height: 1920),
        preferredTransform: .identity,
        nominalFrameRate: 30,
        hasAudio: true
    )
    let snapshot = ProjectSnapshot(
        name: "x",
        timeline: EditTimeline(sources: [source], clips: []),
        subtitleEntries: [],
        subtitleStyle: .classic
    )
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let videoURL = dir.appendingPathComponent("a.mp4")
    try ProjectStore.save(snapshot, for: videoURL)

    let loaded = try #require(ProjectStore.load(for: videoURL))
    #expect(loaded.version == 2)
    #expect(loaded.timeline.sources.first?.id == source.id)
}
```

Тесту нужен `import CoreMedia` и `import CoreGraphics` — добавить.

- [ ] **Step 2: Убедиться, что тест падает**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS' -only-testing:RECoreTests/legacySidecarGetsSynthesizedSource`
Expected: FAIL — нет свойства `version`.

- [ ] **Step 3: Добавить `version` в `ProjectSnapshot`**

`public var version: Int` со значением 2 в `init` и `decodeIfPresent(...) ?? 1` в декодере.

- [ ] **Step 4: Миграция в `ProjectStore.load(from:)`**

После декодирования: если `version < 2`, собрать `MediaSource` по каждому уникальному `legacySourceURL` клипов, проставить клипам `sourceID`, очистить `legacySourceURL`. Метаданные-заглушки: `duration` — из `availableRange` клипа, `naturalSize` — `.zero`, `preferredTransform` — `.identity`, `nominalFrameRate` — 30, `hasAudio` — `true`. Настоящие значения дозаполнит `EditorViewModel` при импорте (Task 5), потому что `ProjectStore` синхронный и не может ждать `AVURLAsset`.

- [ ] **Step 5: Почистить `Project`**

Удалить `sourceURL`, `sourceBookmarkData`, `createBookmark()`, `resolveBookmark()`. Работа с bookmark переезжает в `MediaSource` (Task 5). Оставить `name`, `timeline`, `createdAt`, `modifiedAt`.

- [ ] **Step 6: Прогнать тесты**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS' -only-testing:RECoreTests`
Expected: PASS, включая существующие `ProjectStoreTests`.

- [ ] **Step 7: Коммит**

```bash
git add Sources/RECore Tests/RECoreTests SilenceCut.xcodeproj
git commit -m "feat(core): формат проекта v2 и миграция старых sidecar"
```

---

## Task 4: Сборка композиции из разнородных источников

**Files:**
- Modify: `Sources/RETimeline/CompositionBuilder.swift`
- Create: `Tests/RETimelineTests/ClipFramingTests.swift`
- Modify: `Tests/RETimelineTests/RenderTransformTests.swift` (новая сигнатура)

**Interfaces:**
- Consumes: `EditTimeline.sources/clips/overlays`, `ClipFraming` (Tasks 1–2).
- Produces: `CompositionBuilder.renderTransform(sourceTransform:orientedSize:targetSize:framing:zoom:)`; `CompositionBuilder.projectRenderSize(timeline:options:) -> CGSize`; `CompositionBuilder.projectFrameRate(timeline:) -> Int`; `Result.composition` с тремя дорожками.

- [ ] **Step 1: Написать падающие тесты кадрирования**

```swift
// Tests/RETimelineTests/ClipFramingTests.swift
import Testing
import Foundation
import CoreGraphics
import CoreMedia
@testable import RETimeline
import RECore

private let vertical = CGSize(width: 1080, height: 1920)
private let horizontal = CGSize(width: 1920, height: 1080)

@Test func framingScaleMultipliesFillScale() {
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: ClipFraming(scale: 1.5, offset: .zero), zoom: 1.0
    )
    #expect(abs(t.a - 1.5) < 0.0001)
}

@Test func framingCombinesWithJumpCutZoom() {
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: ClipFraming(scale: 1.2, offset: .zero), zoom: 1.1
    )
    #expect(abs(t.a - 1.32) < 0.0001)
}

@Test func fitScaleShowsWholeHorizontalFrameInVerticalCanvas() {
    // «Вписать целиком»: 16:9 в 9:16 — по ширине, значит fitScale/fillScale
    let fill = max(vertical.width / horizontal.width, vertical.height / horizontal.height)
    let fit = min(vertical.width / horizontal.width, vertical.height / horizontal.height)
    let framing = ClipFraming(scale: fit / fill, offset: .zero)
    let t = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: horizontal, targetSize: vertical,
        framing: framing, zoom: 1.0
    )
    // Кадр целиком помещается по ширине и не вылезает
    let scaledWidth = horizontal.width * t.a
    #expect(abs(scaledWidth - vertical.width) < 0.01)
    #expect(horizontal.height * t.d <= vertical.height + 0.01)
}

@Test func framingOffsetShiftsInCanvasFractions() {
    let base = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: .default, zoom: 1.0
    )
    let shifted = CompositionBuilder.renderTransform(
        sourceTransform: .identity, orientedSize: vertical, targetSize: vertical,
        framing: ClipFraming(scale: 1.0, offset: CGPoint(x: 0.25, y: 0)), zoom: 1.0
    )
    #expect(abs((shifted.tx - base.tx) - vertical.width * 0.25) < 0.01)
}

@Test func projectRenderSizeIsAlwaysEven() {
    let source = MediaSource(
        url: URL(fileURLWithPath: "/a.mp4"),
        duration: CMTime(seconds: 10, preferredTimescale: 600),
        naturalSize: CGSize(width: 1919, height: 1081),
        preferredTransform: .identity, nominalFrameRate: 30, hasAudio: true
    )
    let timeline = EditTimeline(sources: [source], clips: [
        TimelineClip(sourceID: source.id,
                     availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
                     sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)))
    ])
    let size = CompositionBuilder.projectRenderSize(timeline: timeline, options: .default)
    #expect(Int(size.width) % 2 == 0)
    #expect(Int(size.height) % 2 == 0)
}

@Test func projectFrameRateTakesMaximumAcrossSources() {
    func source(_ fps: Double) -> MediaSource {
        MediaSource(url: URL(fileURLWithPath: "/\(fps).mp4"),
                    duration: CMTime(seconds: 10, preferredTimescale: 600),
                    naturalSize: CGSize(width: 1920, height: 1080),
                    preferredTransform: .identity, nominalFrameRate: fps, hasAudio: true)
    }
    let a = source(25), b = source(50)
    let timeline = EditTimeline(sources: [a, b], clips: [
        TimelineClip(sourceID: a.id,
                     availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)),
                     sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))),
        TimelineClip(sourceID: b.id,
                     availableRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)),
                     sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))),
    ])
    #expect(CompositionBuilder.projectFrameRate(timeline: timeline) == 50)
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme RETimeline -configuration Debug build`
Expected: FAIL — у `renderTransform` нет параметра `framing`.

- [ ] **Step 3: Расширить `renderTransform` и добавить чистые хелперы**

`renderTransform(sourceTransform:orientedSize:targetSize:framing:zoom:)`: `scale = fillScale × framing.scale × zoom`, центрирование как сейчас, затем сдвиг на `framing.offset.x × targetSize.width` и `framing.offset.y × targetSize.height`.

`projectRenderSize(timeline:options:)`: `options.outputAspect.renderSize`, иначе ориентированный размер источника первого включённого клипа хребта; результат округляется до чётных вниз, минимум 2×2.

`projectFrameRate(timeline:)`: максимум `nominalFrameRate` по источникам включённых клипов хребта, зажатый в 24…60, округлённый.

Обновить существующие вызовы в `RenderTransformTests.swift`, добавив `framing: .default`.

- [ ] **Step 4: Переписать `build(from:options:)`**

- Три дорожки: `videoTrack` (хребет), `overlayTrack`, `audioTrack`.
- Хребет: для каждого включённого клипа взять `timeline.source(for: clip.sourceID)`; вставить видео; если `source.hasAudio` — вставить звук, иначе `audioTrack.insertEmptyTimeRange(...)` на `clip.sourceRange.duration`, чтобы не уехал синхрон.
- Метаданные брать из `MediaSource`, а не из `AVURLAsset` — `loadTracks` остаётся нужен только для получения самой дорожки.
- Перебивки: вставить в `overlayTrack` по `timelineStart`; при пропуске между перебивками — `insertEmptyTimeRange`; обрезать по длине хребта.
- Одна `AVMutableVideoCompositionInstruction` на весь таймлайн, два `layerInstruction`. У хребта — `setTransform` в начале каждого клипа с его `framing` и джамп-кат зумом. У перебивок — `setTransform` в начале каждой и `setOpacity(1)` в начале, `setOpacity(0)` в конце.
- `audioMix`: рампы 30 мс на склейках, громкость сегмента = `options.audioGain × source.gain`.

- [ ] **Step 5: Определить порядок слоёв фактом**

Собрать композицию из двух синтетических фикстур (сплошной красный и сплошной синий mp4, генерируются `AVAssetWriter` во временную папку), поставить синюю перебивку поверх красного хребта, снять кадр через `AVAssetImageGenerator` в середине перебивки и проверить, что он синий. Если кадр красный — поменять порядок `layerInstructions` местами. Тест положить в `Tests/RETimelineTests/OverlayCompositionTests.swift` и оставить в наборе: он же страхует от регрессии.

- [ ] **Step 6: Прогнать тесты**

Run: `xcodegen generate && xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS' -only-testing:RETimelineTests`
Expected: PASS.

- [ ] **Step 7: Коммит**

```bash
git add Sources/RETimeline Tests/RETimelineTests SilenceCut.xcodeproj
git commit -m "feat(timeline): дорожка перебивок, кадрирование и холст проекта"
```

---

## Task 5: Экспорт — фиксированный формат звука

**Files:**
- Modify: `Sources/REExport/ExportService.swift:275`, `:298-317`

**Interfaces:**
- Consumes: `CompositionBuilder.Result` (Task 4).
- Produces: экспорт, не зависящий от форматов исходников.

- [ ] **Step 1: Задать формат чтения**

Заменить `AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)` на явный LPCM:

```swift
let ao = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48000,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false,
    AVLinearPCMIsBigEndianKey: false
])
```

- [ ] **Step 2: Задать параметры AAC от проекта**

Убрать чтение `formatDescriptions` первой дорожки: `AVSampleRateKey: 48000`, `AVNumberOfChannelsKey: 2`.

- [ ] **Step 3: Проверить экспорт вручную**

Собрать приложение, импортировать ролик, экспортировать, открыть результат — звук на месте, длительность совпадает с таймлайном.

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Коммит**

```bash
git add Sources/REExport
git commit -m "fix(export): фиксированный LPCM 48 кГц на чтении и AAC от проекта"
```

---

## Task 6: Вьюмодель — источники, добавление, пер-клиповая детекция

**Files:**
- Modify: `Sources/REUI/EditorViewModel.swift`

**Interfaces:**
- Consumes: всё из Tasks 1–4.
- Produces: `EditorViewModel.addSources(urls: [URL])`, `.mainSourceURL: URL?`, `.analyses: [MediaSource.ID: SourceAnalysis]`, `.waveforms: [MediaSource.ID: WaveformData]`, `.addOverlay(url:at:)`, `.moveOverlay(id:to:)`, `.trimOverlay(id:newSourceRange:)`, `.removeOverlay(id:)`, `.setFraming(_:forClip:)`, `.offlineSourceIDs: Set<MediaSource.ID>`.

- [ ] **Step 1: Ввести реестр и `addSources`**

`importVideo(url:)` становится тонкой обёрткой над `addSources(urls:)` для случая «первый ролик»: сбрасывает состояние и добавляет один источник. `addSources` загружает метаданные (`duration`, `naturalSize`, `preferredTransform`, `nominalFrameRate`, `hasAudio`), создаёт bookmark, добавляет `MediaSource` в `timeline.sources`, кладёт клип в конец хребта, запускает анализ звука и обновляет превью.

Security-scoped доступ: вместо одного `securityScopedURL` — словарь `[MediaSource.ID: URL]`, доступ снимается при удалении источника и в `deinit`.

Отказы при добавлении: файл без видеодорожки отклоняется с сообщением «В файле нет видео: <имя>» и в реестр не попадает; повторное добавление того же URL переиспользует существующий `MediaSource`, а не плодит дубль. Ошибка или отмена анализа звука не роняет проект — источник просто остаётся без кешей, и детекция пауз по его клипам недоступна.

- [ ] **Step 2: Заменить `project.sourceURL` во всех девяти местах**

`mainSourceURL` = `timeline.sources.first?.url`. Автосохранение и `saveProjectNow` привязываются к нему. `restoreOriginal` восстанавливает исходный клип каждого источника вместо одного.

- [ ] **Step 3: Кеши анализа на источник**

`SourceAnalysis { waveform, rms }`, словарь по `MediaSource.ID`. `ensureRMSCache(for:)` вместо глобального. `waveformData` заменяется на `waveforms: [MediaSource.ID: WaveformData]`.

- [ ] **Step 4: Пер-клиповая детекция пауз**

`SilenceReviewZone` получает `clipID`. `enterSilenceReview()` проходит по всем включённым клипам хребта, для каждого берёт RMS-кеш его источника и детектит внутри `clip.sourceRange`. `displayZones` считает время таймлайна из офсета клипа, а не через глобальный маппинг. `applySilenceReview()` вызывает `splitClipBySpeechRanges` по каждому затронутому клипу вместо пересборки таймлайна.

- [ ] **Step 5: Громкость на источник**

`applyLoudnessNormalization()` замеряет каждый источник, у которого `integratedLUFS == nil`, и пишет `integratedLUFS` и `gain` прямо в `timeline.sources[i]`. Общий `renderOptions.audioGain` остаётся мастером и в нормализации больше не участвует.

- [ ] **Step 6: Операции с перебивками**

`addOverlay(url:at:)` — добавляет источник, если новый, и кладёт `OverlayClip` на указанное время; `moveOverlay`, `trimOverlay`, `removeOverlay` — с сохранением undo-снимка и перестройкой превью. Все они уходят в `saveUndoState()` и `scheduleAutosave()`.

- [ ] **Step 7: Offline-источники**

При открытии проекта разрешать bookmark каждого источника; если файл недоступен — id в `offlineSourceIDs`. `canExport` возвращает `false`, пока множество не пусто, `statusMessage` называет недостающий файл.

- [ ] **Step 8: Сборка**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Коммит**

```bash
git add Sources/REUI
git commit -m "feat(ui): реестр источников, пер-клиповая детекция пауз, громкость на источник"
```

---

## Task 7: Таймлайн в две дорожки (macOS)

**Files:**
- Modify: `Sources/REUI/TimelineView.swift` (секция macOS, строки 25–517)

**Interfaces:**
- Consumes: `EditorViewModel` операции из Task 6.
- Produces: `TimelineViewWrapper` с колбэками `onDropOverlay(URL, CMTime)`, `onMoveOverlay(UUID, CMTime)`, `onTrimOverlay(UUID, CMTimeRange)`, `onSelectOverlay(UUID?)`.

- [ ] **Step 1: Разделить холст на две дорожки**

Верхняя треть высоты — перебивки, нижние две трети — хребет с волной. Слои перебивок рисуются как отдельные `CALayer` с именем источника.

- [ ] **Step 2: Дроп из Finder**

`registerForDraggedTypes([.fileURL])`, `draggingEntered` подсвечивает целевую дорожку, `performDragOperation` определяет дорожку по Y и время по X, зовёт `onDropOverlay` или добавление в хребет.

- [ ] **Step 3: Перетаскивание и тяга краёв**

В `handlePan`: если начало жеста внутри перебивки, определить зону — левый край, правый край, середина (по 8 pt на края). Середина двигает `timelineStart`, края тянут `sourceRange`. Магнит 6 pt к границам клипов хребта и к плейхеду.

- [ ] **Step 4: Волна по клипам**

`updateTimeline` принимает `waveforms: [UUID: WaveformData]` и режет каждую по `sourceRange` своего клипа вместо одной волны на весь таймлайн.

- [ ] **Step 5: Проверка вручную**

Собрать, кинуть второй ролик на верхнюю дорожку, подвинуть, потянуть края, убедиться, что превью совпадает.

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Коммит**

```bash
git add Sources/REUI/TimelineView.swift
git commit -m "feat(ui): вторая дорожка таймлайна с дропом и тягой перебивок"
```

---

## Task 8: Кадрировщик и полка источников

**Files:**
- Create: `Sources/REUI/FramingOverlayView.swift`, `Sources/REUI/SourceShelfView.swift`
- Modify: `Sources/REUI/MainEditorView.swift`, `Sources/SilenceCutApp/SilenceCutApp.swift:150-165`

**Interfaces:**
- Consumes: `EditorViewModel.setFraming(_:forClip:)`, `.addSources(urls:)` (Task 6).

- [ ] **Step 1: Рамка кадрирования**

`FramingOverlayView` поверх `PreviewPlayerView` при выделенном клипе: драг меняет `offset` в долях холста, скролл и пинч меняют `scale`. Кнопки «Заполнить» (`scale = 1`), «Вписать» (`scale = fit/fill`), «Сбросить» (`.default`).

- [ ] **Step 2: Полка источников**

Горизонтальный список чипов над таймлайном: имя файла, длительность, статус анализа, LUFS. Кнопка «Добавить видео» с `allowsMultipleSelection = true`. Чип тянется на дорожки таймлайна. Красный чип у offline-источника с кнопкой «Найти файл…».

- [ ] **Step 3: Мультивыбор в панелях приложения**

`allowsMultipleSelection = true` в `SilenceCutApp.swift:152` и `:161`, `MainEditorView.swift:263`; обработчики зовут `addSources(urls:)`.

- [ ] **Step 4: «Сохранить как…»**

Добавить в `ProjectStore` перегрузку `save(_ snapshot: ProjectSnapshot, to url: URL) throws`, пишущую по прямому пути (существующая `save(_:for:)` начинает вызывать её, посчитав `sidecarURL`). Пункт меню «Сохранить как…» с `NSSavePanel` и расширением `silencecut`.

- [ ] **Step 5: Сборка и ручная проверка**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Коммит**

```bash
git add Sources/REUI Sources/SilenceCutApp SilenceCut.xcodeproj
git commit -m "feat(ui): кадрировщик в превью и полка источников"
```

---

## Task 9: iOS и финальная проверка

**Files:**
- Modify: `Sources/REUI/MainEditorView.swift` (ветка iOS), `Sources/REUI/TimelineView.swift` (секция iOS)

- [ ] **Step 1: Собрать iOS**

Run:
```bash
xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED. Починить обращения к удалённым `project.sourceURL` и `waveformData`.

- [ ] **Step 2: Перебивки на iOS — только отрисовка**

iOS-таймлайн рисует перебивки на верхней дорожке, но не даёт их двигать: жесты остаются за скрабом и хребтом.

- [ ] **Step 3: Полный прогон тестов**

Run: `xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS'`
Expected: PASS для `RECoreTests`, `REAudioAnalysisTests`, `RETimelineTests`.

- [ ] **Step 4: Обновить AGENTS.md**

Дописать в раздел «Архитектура» опорные точки: реестр `MediaSource` внутри `EditTimeline`, модель «хребет + перебивки», `applyRemovals` как единственный путь укорачивания таймлайна.

- [ ] **Step 5: Коммит**

```bash
git add -A
git commit -m "feat: мультиклиповый таймлайн с разнородными исходниками"
```
