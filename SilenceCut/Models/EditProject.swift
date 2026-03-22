import Foundation

/// Represents a video editing project
@Observable
class EditProject {
    /// Source video file URL
    var sourceURL: URL?
    /// Silence detection configuration
    var silenceSettings: SilenceDetectionSettings = .normal
    /// Export configuration
    var exportSettings: ExportSettings = ExportSettings()
    /// Whether silence has been detected
    var silenceDetected: Bool = false
    /// Duration of the source video in seconds
    var sourceDuration: Double = 0
    /// Project name (derived from filename)
    var name: String {
        sourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}

struct ExportSettings: Codable, Equatable {
    var preset: ExportPreset = .high
    var format: ExportFormat = .mp4

    enum ExportPreset: String, Codable, CaseIterable {
        case original = "Original"
        case high = "High (1080p)"
        case medium = "Medium (720p)"
        case low = "Low (480p)"
    }

    enum ExportFormat: String, Codable, CaseIterable {
        case mp4 = "MP4 (H.264)"
        case hevc = "MP4 (HEVC)"
        case mov = "MOV (ProRes)"
    }
}
