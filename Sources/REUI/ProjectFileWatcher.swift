#if os(macOS)
import Foundation

/// Слежение за файлом проекта: приложение должно замечать правки, сделанные CLI.
///
/// Следим за ПАПКОЙ, а не за самим файлом. `ProjectStore` пишет атомарно, то есть создаёт
/// временный файл и подменяет им старый; дескриптор исходного файла после такой подмены
/// указывает на удалённый инод и больше никаких событий не приносит. Папка переживает
/// подмену и продолжает сообщать о записи.
final class ProjectFileWatcher {

    /// Отпечаток файла: по нему отличается чужая правка от своей собственной.
    ///
    /// Читается через `FileManager`, а НЕ через `URL.resourceValues`: последний кеширует
    /// значения на объекте URL и после подмены файла продолжает отдавать старые размер и
    /// дату. Слежение при этом исправно получает события, но каждый раз решает, что ничего
    /// не изменилось, — и правки снаружи молча теряются.
    struct Signature: Equatable {
        let modified: Date
        let size: Int

        init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int else {
                return nil
            }
            self.modified = modified
            self.size = size
        }
    }

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounce: DispatchWorkItem?

    private let url: URL
    private let onChange: () -> Void

    /// Отпечаток последней записи, сделанной самим приложением
    private var ownSignature: Signature?

    init?(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        self.ownSignature = Signature(of: url)

        let directory = url.deletingLastPathComponent()
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.handleEvent() }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source.resume()
        self.source = source
    }

    deinit { stop() }

    func stop() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    /// Приложение только что записало проект — запомнить отпечаток, чтобы не принять
    /// собственную запись за чужую правку
    func noteOwnWrite() {
        ownSignature = Signature(of: url)
    }

    private func handleEvent() {
        // Запись в папку прилетает пачкой (временный файл, подмена, метаданные) —
        // схлопываем, иначе проект перечитается несколько раз подряд
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkForExternalChange() }
        debounce = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func checkForExternalChange() {
        guard let current = Signature(of: url) else { return }
        guard current != ownSignature else { return }
        ownSignature = current
        DispatchQueue.main.async { [onChange] in onChange() }
    }
}
#endif
