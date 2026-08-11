import Foundation

/// `silencecut` — управление проектом монтажа снаружи приложения.
///
/// Существует ради конвейера с Remotion: титр рендерится отдельным процессом, а положить
/// его в монтаж должен кто-то, кто понимает формат проекта. Работает и когда приложение
/// закрыто; открытое приложение замечает правку по слежению за файлом.

let usage = """
silencecut — правка проекта .silencecut снаружи приложения

СОЗДАНИЕ
  new <проект> --video <файл> [--name <имя>] [--force]

ЧТЕНИЕ
  info <проект>                    сводка: длительность, холст, число клипов
  canvas <проект>                  размер холста и fps — что нужно рендереру титров
  list <проект> [--sources] [--clips] [--overlays] [--graphics]
                                   без флагов печатает всё
  validate <проект>                пропавшие файлы, осиротевшие клипы, титры за концом
                                   выход 1, если нашлись проблемы

ПРАВКА
  add-graphic <проект> --file <файл> --at <секунды>
              [--duration <секунды>] [--source-start <секунды>]
              [--template <имя>] [--props <json>] [--pack-version <версия>]
  move-graphic <проект> --id <uuid> --at <секунды>
  remove-graphic <проект> --id <uuid>

Читающие команды печатают JSON.

ПРИМЕР
  silencecut canvas ~/Проекты/ролик.silencecut
  silencecut add-graphic ~/Проекты/ролик.silencecut \\
      --file ~/render/lower-third.mov --at 12.5 \\
      --template LowerThird --props '{"title":"Как открыть ИП"}'
"""

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

guard !arguments.command.isEmpty, !arguments.has("help") else {
    print(usage)
    exit(arguments.has("help") ? 0 : 1)
}

do {
    switch arguments.command {
    case "new":            try await Commands.new(arguments)
    case "info":           try Commands.info(arguments)
    case "canvas":         try Commands.canvas(arguments)
    case "list":           try Commands.list(arguments)
    case "validate":       try Commands.validate(arguments)
    case "add-graphic":    try await Commands.addGraphic(arguments)
    case "move-graphic":   try Commands.moveGraphic(arguments)
    case "remove-graphic": try Commands.removeGraphic(arguments)
    case "help":           print(usage)
    default:
        throw CLIError.unknownCommand(arguments.command)
    }
} catch {
    // Ошибки в stderr, чтобы разбор stdout как JSON не спотыкался о текст для человека
    FileHandle.standardError.write(Data("Ошибка: \(error.localizedDescription)\n".utf8))
    exit(1)
}
