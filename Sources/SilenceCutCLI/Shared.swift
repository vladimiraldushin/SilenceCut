import Foundation
import CoreMedia
import RECore

/// Общее для всех команд: чтение и запись проекта, разбор аргументов, вывод.
///
/// Вынесено отдельно, потому что каждая команда делает одно и то же вокруг своей
/// сути — прочитать, поправить, записать с обновлённой датой. Разъехавшиеся варианты
/// этой обвязки означали бы, что часть команд не обновляет `savedAt` и приложение
/// не замечает их правок.
enum Shared {

    static func load(_ url: URL) throws -> ProjectSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound(url.path)
        }
        return try ProjectStore.load(from: url)
    }

    /// Запись с обновлённой датой: по ней приложение понимает, что файл переписали
    static func save(_ snapshot: ProjectSnapshot, to url: URL) throws {
        var updated = snapshot
        updated.savedAt = Date()
        try ProjectStore.save(updated, to: url)
    }

    /// Файл уже в реестре — переиспользуем запись. Один и тот же ролик, вставленный
    /// дважды, не должен плодить источники.
    static func resolveSource(_ url: URL, in timeline: inout EditTimeline) async throws -> MediaSource {
        let standardized = url.standardizedFileURL.path
        if let existing = timeline.sources.first(where: {
            $0.url.standardizedFileURL.path == standardized
        }) {
            return existing
        }
        let source = try await MediaSource.load(from: url)
        timeline.sources.append(source)
        return source
    }

    static func fileArgument(_ args: Arguments, key: String) throws -> URL {
        let path = try args.requireString(key)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound(url.path)
        }
        return url
    }

    static func uuid(_ raw: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else {
            throw CLIError.invalid("Не похоже на идентификатор: \(raw)")
        }
        return value
    }

    static func seconds(_ time: CMTime) -> Double {
        round3(CMTimeGetSeconds(time))
    }

    static func round3(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000).rounded() / 1000
    }

    /// Число для человека в тексте предупреждения
    static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Настоящий stdout, отложенный до того, как его подменят.
    ///
    /// Фреймворки печатают отладку обычным `print()`, то есть в stdout: «[Export] done»,
    /// «[ParakeetEngine] Model loaded» и прочее. Для человека это полезно, но JSON на
    /// выходе оно превращает в мусор, который не разбирается. Поэтому на старте stdout
    /// уводится в stderr, а результат печатается сюда — в сохранённый дескриптор.
    private static let realStdout: Int32 = {
        let saved = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        return saved
    }()

    /// Вызывается один раз на старте, чтобы подмена случилась до первого чужого print
    static func captureStdout() {
        _ = realStdout
    }

    static func printJSON(_ value: Any) {
        // Ленивые коллекции вроде ReversedCollection роняют JSONSerialization
        // исключением Objective-C, которое Swift не поймает. Лучше внятная ошибка.
        guard JSONSerialization.isValidJSONObject(value) else {
            FileHandle.standardError.write(Data(
                "Ошибка: результат не сериализуется в JSON — приведите коллекции к Array\n".utf8
            ))
            exit(1)
        }
        guard var data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buffer in
            _ = write(realStdout, buffer.baseAddress, buffer.count)
        }
    }
}
