import Foundation

/// Разбор аргументов вида `--ключ значение` и флагов `--флаг`.
///
/// Написано руками вместо swift-argument-parser сознательно: набор команд маленький и
/// стабильный, а лишний пакет в сборке — это лишняя точка отказа в инструменте, который
/// должен просто работать.
struct Arguments {
    let command: String
    let positional: [String]
    private let options: [String: String]
    private let flags: Set<String>

    init(_ raw: [String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []

        var index = 0
        var command = ""
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                // Следующий токен — значение, если он не начинается с --
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[key] = raw[index + 1]
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            } else {
                if command.isEmpty {
                    command = token
                } else {
                    positional.append(token)
                }
                index += 1
            }
        }

        self.command = command
        self.positional = positional
        self.options = options
        self.flags = flags
    }

    func string(_ key: String) -> String? { options[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }

    func double(_ key: String) -> Double? {
        guard let raw = options[key] else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    func requireString(_ key: String) throws -> String {
        guard let value = options[key] else {
            throw CLIError.missingOption("--\(key)")
        }
        return value
    }

    func requireDouble(_ key: String) throws -> Double {
        guard let value = double(key) else {
            throw CLIError.missingOption("--\(key)")
        }
        return value
    }

    /// Путь к проекту: первый позиционный аргумент или `--project`
    func projectURL() throws -> URL {
        let path = options["project"] ?? positional.first
        guard let path else { throw CLIError.missingOption("путь к проекту") }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

enum CLIError: Error, LocalizedError {
    case missingOption(String)
    case unknownCommand(String)
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missingOption(let name): return "Не хватает аргумента: \(name)"
        case .unknownCommand(let name): return "Неизвестная команда: \(name)"
        case .notFound(let what): return "Не найдено: \(what)"
        case .invalid(let why): return why
        }
    }
}
