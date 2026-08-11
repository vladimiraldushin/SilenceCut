import Foundation

/// `silencecut` — управление проектом монтажа снаружи приложения.
///
/// Существует ради конвейера с Remotion: заставки и титры рендерятся отдельным процессом,
/// а положить их в монтаж должен кто-то, кто понимает формат проекта и умеет двигать за
/// собой субтитры, перебивки и графику. Работает и когда приложение закрыто; открытое
/// приложение замечает правку по слежению за файлом.

let usage = """
silencecut — монтаж из командной строки

ПРОЕКТ
  new <проект> --video <файл> [--name <имя>] [--force]
  info <проект>                    сводка: длительность, холст, состав
  canvas <проект>                  размер холста и fps — это нужно рендереру графики
  list <проект> [--sources] [--clips] [--overlays] [--graphics] [--subtitles]
  validate <проект>                пропавшие файлы, сироты, наложения, вылет за конец
                                   код выхода 1, если нашлись проблемы

ХРЕБЕТ (видео со звуком)
  add-clip <проект> --file <файл> [--at <сек>] [--duration <сек>] [--source-start <сек>]
                                   без --at кладёт в конец; --at 0 это заставка
  remove-clip <проект> --id <uuid>
  move-clip <проект> --id <uuid> --to-boundary <номер стыка>
  split-clip <проект> --at <сек>
  toggle-clip <проект> --id <uuid>
  trim-clip <проект> --id <uuid> [--source-start <сек>] [--duration <сек>]
  set-framing <проект> --id <uuid> [--scale 1.6] [--x 0.1] [--y -0.05]
              [--end-scale 2.2] [--end-x 0.05] [--end-y -0.08] [--static]
                                   наезд внутри клипа: кадр едет от начального
                                   положения к конечному

ПЕРЕБИВКИ (картинка поверх, звук хребта идёт дальше)
  add-overlay <проект> --file <файл> --at <сек> [--duration <сек>] [--source-start <сек>]
  move-overlay <проект> --id <uuid> --at <сек>
  remove-overlay <проект> --id <uuid>

ГРАФИКА (титры с прозрачностью, поверх всего)
  add-graphic <проект> --file <файл> --at <сек> [--duration <сек>]
              [--template <имя>] [--props <json>] [--pack-version <версия>]
  move-graphic <проект> --id <uuid> --at <сек>
  remove-graphic <проект> --id <uuid>

ПРОСМОТР
  frame <проект> [--at 5,20,60 | --count 12 | --every 30] [--sheet] [--columns 5]
                 [--width 480] [--out-dir <папка>]
                                   кадры СОБРАННОГО монтажа: с кадрированием,
                                   перебивками и титрами, а не сырой исходник

ЗВУК И РЕЧЬ
  transcribe <проект> [--model parakeet-v3] [--language ru] [--srt <файл>] [--apply]
                                   расшифровка смонтированного звука.
                                   БЕЗ --apply в проект ничего не пишется

РЕНДЕР
  detect-silence <проект> [--apply] [--threshold <дБ>] [--min-duration <сек>] [--padding <сек>]
                                   без --apply только показывает, сколько вырежется
  level-audio <проект> [--apply] [--target <дБ>] [--headroom 1] [--max-boost 18]
                                   выравнивает тихие клипы по медиане ролика,
                                   не выходя за пик
  export <проект> --out <файл> [--preset high|medium|low] [--subtitles]
                               [--aspect 9:16|1:1|16:9|source] [--force]

ИСТОЧНИКИ
  relink-source <проект> --id <uuid> --file <файл>    файл переехал
  prune-sources <проект>                               убрать неиспользуемые

Читающие команды печатают JSON, ошибки идут в stderr.

ПРИМЕР — заставка в начало и титр под первую фразу
  silencecut add-clip ~/ролик.silencecut --file ~/заставка.mov --at 0
  silencecut list ~/ролик.silencecut --subtitles
  silencecut add-graphic ~/ролик.silencecut --file ~/титр.mov --at 5.2 --duration 3
"""

// До первого чужого print: фреймворки пишут отладку в stdout и портят JSON
Shared.captureStdout()

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

guard !arguments.command.isEmpty, !arguments.has("help") else {
    print(usage)
    exit(arguments.has("help") ? 0 : 1)
}

do {
    switch arguments.command {
    // Проект
    case "new":             try await Commands.new(arguments)
    case "info":            try Commands.info(arguments)
    case "canvas":          try Commands.canvas(arguments)
    case "list":            try Commands.list(arguments)
    case "validate":        try Commands.validate(arguments)

    // Хребет
    case "add-clip":        try await ClipCommands.addClip(arguments)
    case "remove-clip":     try ClipCommands.removeClip(arguments)
    case "move-clip":       try ClipCommands.moveClip(arguments)
    case "split-clip":      try ClipCommands.splitClip(arguments)
    case "toggle-clip":     try ClipCommands.toggleClip(arguments)
    case "trim-clip":       try ClipCommands.trimClip(arguments)
    case "set-framing":     try ClipCommands.setFraming(arguments)

    // Перебивки
    case "add-overlay":     try await ClipCommands.addOverlay(arguments)
    case "move-overlay":    try ClipCommands.moveOverlay(arguments)
    case "remove-overlay":  try ClipCommands.removeOverlay(arguments)

    // Графика
    case "add-graphic":     try await Commands.addGraphic(arguments)
    case "move-graphic":    try Commands.moveGraphic(arguments)
    case "remove-graphic":  try Commands.removeGraphic(arguments)

    // Источники
    case "relink-source":   try await ClipCommands.relinkSource(arguments)
    case "prune-sources":   try ClipCommands.pruneSources(arguments)

    // Просмотр и рендер
    case "frame":           try await FrameCommands.frame(arguments)
    case "transcribe":      try await TranscribeCommands.transcribe(arguments)
    case "export":          try await RenderCommands.export(arguments)
    case "detect-silence":  try await RenderCommands.detectSilence(arguments)
    case "level-audio":     try await LevelCommands.levelAudio(arguments)

    case "help":            print(usage)
    default:
        throw CLIError.unknownCommand(arguments.command)
    }
} catch {
    // Ошибки в stderr, чтобы разбор stdout как JSON не спотыкался о текст для человека
    FileHandle.standardError.write(Data("Ошибка: \(error.localizedDescription)\n".utf8))
    exit(1)
}
