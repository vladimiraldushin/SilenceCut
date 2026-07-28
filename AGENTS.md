# SilenceCut — заметки для AI-агентов

## Как собирать и тестировать

Проект генерируется XcodeGen: после добавления/удаления файлов в `Sources/` или `Tests/` нужен `xcodegen generate` (иначе новый файл не попадёт в таргет).

```bash
xcodegen generate
xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug build
xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut -configuration Debug test -destination 'platform=macOS'
xcodebuild -project SilenceCut.xcodeproj -scheme SilenceCut-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Схема `SilenceCut` прогоняет все тест-таргеты: `RECoreTests`, `REAudioAnalysisTests`, `RETimelineTests`. Отдельные фреймворки собираются своими схемами (`RECore`, `RETimeline`, `REAudioAnalysis`, `REExport`, `REUI`) — удобно для быстрой проверки одного модуля.

## Архитектура

Слои (зависимости строго в одну сторону): `RECore` → `RETimeline` / `REAudioAnalysis` → `REExport` → `REUI` → приложения (`SilenceCutApp` для macOS, `SilenceCutIOSApp` для iOS). Оба приложения используют один `MainEditorView` с платформенными ветками.

Опорные точки, которые стоит знать перед правками:

- **`RECore/EditTimeline`** — модель монтажа (EDL): массив `TimelineClip` со ссылками на исходник и диапазонами. Исходный файл никогда не меняется; все операции — над этой моделью.
- **`RETimeline/CompositionBuilder.build(from:options:)`** — ЕДИНСТВЕННОЕ место, где строится `AVComposition`. Через него идут и превью, и экспорт, поэтому «что видно, то и получится». Здесь же применяются `RenderOptions`: формат кадра с центральным кропом, джамп-кат зум (шаговый `setTransform` на каждой склейке) и гейн громкости в `audioMix`. Математика вынесена в чистую `renderTransform(...)` и покрыта тестами.
- **`REExport/ExportService.export(...)`** — однопроходный экспорт: `AVAssetReaderVideoCompositionOutput` → отрисовка субтитров Core Graphics прямо на кадрах → `AVAssetWriter` с битрейтом пресета. Никаких промежуточных файлов и второго кодирования. Отмена — через `ExportCancellationToken`.
- **`REAudioAnalysis/AudioAnalysis.analyze(url:)`** — один потоковый проход по звуку даёт и waveform, и `RMSCache`. Кеш позволяет пересчитывать детекцию тишины (`SilenceDetector.detect(cache:settings:)`) мгновенно, без чтения файла. Память константная — важно для часовых роликов.
- **`RECore/ProjectStore`** — автосохранение проекта в sidecar `<видео>.mp4.silencecut` рядом с исходником; при импорте того же видео состояние восстанавливается.
- **Субтитры** хранятся в ТАЙМЛАЙН-времени (транскрибация идёт по смонтированному звуку), поэтому маппинг source↔timeline для них не нужен.

## Горячие клавиши на macOS

Перехват идёт в `NSEvent`-мониторе в `SilenceCutApp.swift`. Он обязан пропускать события, когда фокус в текстовом поле: проверяется и флаг `viewModel.isTextEditingActive` (его выставляет `@FocusState` в списке субтитров), и цепочка responder'ов. Не добавляй `.onKeyPress` на родительские вью — SwiftUI перехватит пробел раньше `TextField`, и в субтитрах нельзя будет поставить пробел.

## Git: .git вне синка Яндекс.Диска (с 11.07.2026)

Яндекс.Диск повреждал `.git` (терял объекты, плодил конфликтные копии ref'ов), поэтому git-dir вынесен из синка: он лежит в `~/.git-store/silencecut.git`, а `.git` в корне проекта — однострочный файл-указатель `gitdir: ../../../.git-store/silencecut.git`. НЕ заменять этот файл папкой и НЕ переписывать путь на абсолютный (относительный путь одинаков на всех машинах с папкой в `~/Yandex.Disk.localized/`).

Настройка git на новой машине (файлы проекта уже приходят через Диск вместе с указателем):

```bash
git clone --no-checkout --separate-git-dir="$HOME/.git-store/silencecut.git" \
  https://github.com/vladimiraldushin/SilenceCut.git "${TMPDIR:-/tmp}/tmp-clone"
rm -rf "${TMPDIR:-/tmp}/tmp-clone"   # временный worktree не нужен — файлы уже в папке
cd "$HOME/Yandex.Disk.localized/Монтаж/silencecut"
git config core.worktree "$PWD"
git reset   # заполнить индекс из HEAD; git status должен стать чистым
```
