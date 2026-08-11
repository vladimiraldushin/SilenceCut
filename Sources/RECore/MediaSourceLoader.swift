import Foundation
import AVFoundation

/// Чтение метаданных исходника с диска.
///
/// Живёт в RECore, а не во вьюмодели, потому что источник заводят двое: интерфейс при
/// импорте и CLI при вставке титра. Разъехавшиеся представления об одном и том же файле
/// означали бы, что проект, собранный снаружи, рисуется иначе, чем собранный руками.
extension MediaSource {

    public enum LoadError: Error, LocalizedError {
        case noVideoTrack(URL)
        case unreadable(URL, any Error)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack(let url):
                return "В файле нет видеодорожки: \(url.lastPathComponent)"
            case .unreadable(let url, let error):
                return "Не удалось открыть \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Собирает запись реестра по файлу, попутно создавая security-scoped закладку
    public static func load(from url: URL) async throws -> MediaSource {
        let asset = AVURLAsset(url: url)
        do {
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw LoadError.noVideoTrack(url)
            }
            let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            var source = MediaSource(
                url: url,
                duration: try await asset.load(.duration),
                naturalSize: try await videoTrack.load(.naturalSize),
                preferredTransform: try await videoTrack.load(.preferredTransform),
                nominalFrameRate: Double(try await videoTrack.load(.nominalFrameRate)),
                hasAudio: hasAudio
            )
            try? source.createBookmark()
            return source
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.unreadable(url, error)
        }
    }
}
