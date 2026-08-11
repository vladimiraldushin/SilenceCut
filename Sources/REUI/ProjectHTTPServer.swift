#if os(macOS)
import Foundation
import Network

/// Локальный HTTP-доступ к открытому проекту.
///
/// Решает ровно одну задачу, которую CLI решить не может: узнать, ЧТО сейчас открыто.
/// Без этого каждый запрос вида «поставь титр на двенадцатой секунде» начинается с
/// выяснения пути к файлу проекта.
///
/// Намеренно только чтение плюс перечитывание. Правки идут через CLI — он пишет файл,
/// который пользователь и так контролирует, и его действия видны в git и в Finder.
/// Сервер, умеющий менять проект, был бы дырой: любой процесс на машине может постучаться
/// на localhost, и никакой границы доверия здесь нет.
final class ProjectHTTPServer {

    /// Порт по умолчанию. Взят из диапазона, который редко занимают средства разработки.
    static let defaultPort: UInt16 = 8787

    private var listener: NWListener?
    private let port: UInt16
    private let snapshot: @MainActor () -> [String: Any]
    private let reload: @MainActor () -> Void

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(
        port: UInt16 = ProjectHTTPServer.defaultPort,
        snapshot: @escaping @MainActor () -> [String: Any],
        reload: @escaping @MainActor () -> Void
    ) {
        self.port = port
        self.snapshot = snapshot
        self.reload = reload
    }

    deinit { stop() }

    func start() {
        stop()
        do {
            let parameters = NWParameters.tcp
            // Только петля: снаружи машины сервер недоступен вовсе
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: port) ?? .any
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                    self?.lastError = nil
                case .failed(let error):
                    self?.isRunning = false
                    self?.lastError = error.localizedDescription
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Обработка запроса

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // Первая строка запроса: METHOD /path HTTP/1.1
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let method = parts.count > 0 ? String(parts[0]) : ""
            let path = parts.count > 1 ? String(parts[1]) : "/"

            Task { @MainActor in
                let response = self.route(method: method, path: path)
                self.send(response, over: connection)
            }
        }
    }

    @MainActor
    private func route(method: String, path: String) -> (status: String, body: [String: Any]) {
        switch (method, path) {
        case ("GET", "/health"):
            return ("200 OK", ["ok": true, "service": "silencecut"])

        case ("GET", "/project"), ("GET", "/"):
            return ("200 OK", snapshot())

        case ("POST", "/reload"):
            reload()
            return ("200 OK", ["reloaded": true])

        default:
            return ("404 Not Found", [
                "error": "нет такого пути",
                "available": ["GET /project", "GET /health", "POST /reload"],
            ])
        }
    }

    private func send(_ response: (status: String, body: [String: Any]), over connection: NWConnection) {
        let payload = (try? JSONSerialization.data(
            withJSONObject: response.body,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)

        var head = "HTTP/1.1 \(response.status)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
