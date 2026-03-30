import Foundation
import RECore

// MARK: - ASR Engine Protocol

/// Unified result from any ASR engine
public struct ASRSegment: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let words: [(word: String, start: Double, end: Double)]

    public init(text: String, start: Double, end: Double, words: [(word: String, start: Double, end: Double)]) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

/// Abstraction over WhisperKit, FluidAudio/Parakeet, etc.
public protocol ASREngine: AnyObject {
    func loadModel(variant: String, progress: @escaping (Double, String?) -> Void) async throws
    func transcribe(audioPath: String, language: String) async throws -> [ASRSegment]
    func unload()
    var isLoaded: Bool { get }
}

// MARK: - Model Catalog

public enum ASREngineType: String, Codable, CaseIterable, Sendable {
    case whisperKit
    case parakeet
}

public struct ASRModelInfo: Identifiable, Sendable {
    public var id: String { variant }
    public let variant: String
    public let displayName: String
    public let engineType: ASREngineType
    public let approxSizeMB: Int
    public let qualityStars: Int  // 1-5
    public let speedNote: String
}

// MARK: - Model State

public enum ModelState: Equatable {
    case idle
    case downloading(progress: Double, detail: String?)
    case loading
    case ready
    case error(String)

    public static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready): return true
        case (.downloading(let a, _), .downloading(let b, _)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

/// Per-model download state
public enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double, detail: String?)
    case downloaded
    case loadedInMemory

    public static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded), (.downloaded, .downloaded), (.loadedInMemory, .loadedInMemory): return true
        case (.downloading(let a, _), .downloading(let b, _)): return a == b
        default: return false
        }
    }
}

// MARK: - ModelManager

@Observable
public final class ModelManager {

    // MARK: Public state

    public private(set) var state: ModelState = .idle

    /// Per-model download states (variant → state)
    public private(set) var modelStates: [String: ModelDownloadState] = [:]

    public var selectedModelId: String {
        didSet {
            UserDefaults.standard.set(selectedModelId, forKey: "silencecut.selectedModel")
        }
    }

    public var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "silencecut.selectedLanguage")
        }
    }

    public let modelCatalog: [ASRModelInfo] = [
        ASRModelInfo(variant: "whisper-tiny", displayName: "Whisper Tiny", engineType: .whisperKit,
                     approxSizeMB: 75, qualityStars: 1, speedNote: "Самая быстрая"),
        ASRModelInfo(variant: "whisper-base", displayName: "Whisper Base", engineType: .whisperKit,
                     approxSizeMB: 140, qualityStars: 2, speedNote: "Быстрая"),
        ASRModelInfo(variant: "whisper-small", displayName: "Whisper Small", engineType: .whisperKit,
                     approxSizeMB: 460, qualityStars: 3, speedNote: "Баланс"),
        ASRModelInfo(variant: "whisper-large-v3", displayName: "Whisper Large v3", engineType: .whisperKit,
                     approxSizeMB: 3000, qualityStars: 5, speedNote: "Лучшее качество"),
        ASRModelInfo(variant: "parakeet-v3", displayName: "Parakeet v3", engineType: .parakeet,
                     approxSizeMB: 600, qualityStars: 4, speedNote: "Быстрая + качество"),
    ]

    // MARK: Private

    private var engine: ASREngine?
    private var loadedModelId: String?
    private var backgroundTimer: Timer?
    private static let backgroundTimeout: TimeInterval = 120

    // Factory for creating engines — overridable for Parakeet later
    private func makeEngine(for model: ASRModelInfo) -> ASREngine {
        switch model.engineType {
        case .whisperKit:
            return WhisperKitEngine()
        case .parakeet:
            return ParakeetEngine()
        }
    }

    /// WhisperKit variant name from our model ID
    private func whisperVariant(for modelId: String) -> String {
        switch modelId {
        case "whisper-tiny": return "tiny"
        case "whisper-base": return "base"
        case "whisper-small": return "small"
        case "whisper-large-v3": return "large-v3"
        default: return modelId
        }
    }

    /// Background download task
    private var downloadTask: Task<Void, Never>?

    // MARK: Init

    public init() {
        self.selectedModelId = UserDefaults.standard.string(forKey: "silencecut.selectedModel") ?? "whisper-large-v3"
        self.selectedLanguage = UserDefaults.standard.string(forKey: "silencecut.selectedLanguage") ?? "ru"
        // Initialize per-model states
        for model in modelCatalog {
            modelStates[model.variant] = .notDownloaded
        }
        // Check which WhisperKit models are already cached
        scanDownloadedModels()
    }

    /// Scan filesystem for already-downloaded models
    private func scanDownloadedModels() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let hfHub = cacheDir?.appendingPathComponent("huggingface/hub")

        for model in modelCatalog where model.engineType == .whisperKit {
            let variant = whisperVariant(for: model.variant)
            // WhisperKit stores in huggingface/hub/models--argmaxinc--whisperkit-coreml/...
            let repoDir = hfHub?.appendingPathComponent("models--argmaxinc--whisperkit-coreml")
            if let repoDir, FileManager.default.fileExists(atPath: repoDir.path) {
                // Check for the variant folder in snapshots
                if let snapshots = try? FileManager.default.contentsOfDirectory(at: repoDir.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil) {
                    for snapshot in snapshots {
                        let variantDir = snapshot.appendingPathComponent("openai_whisper-\(variant)")
                        if FileManager.default.fileExists(atPath: variantDir.path) {
                            modelStates[model.variant] = .downloaded
                            break
                        }
                    }
                }
            }
        }

        // For Parakeet, check FluidAudio cache
        // FluidAudio uses its own cache — check if models exist
        let fluidDir = cacheDir?.appendingPathComponent("FluidAudio")
        if let fluidDir, FileManager.default.fileExists(atPath: fluidDir.path) {
            // Simple heuristic: if FluidAudio cache dir exists and has content
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: fluidDir.path), !contents.isEmpty {
                modelStates["parakeet-v3"] = .downloaded
            }
        }
    }

    /// Get download state for a specific model
    public func downloadState(for variant: String) -> ModelDownloadState {
        if loadedModelId == variant {
            return .loadedInMemory
        }
        return modelStates[variant] ?? .notDownloaded
    }

    // MARK: - Core Methods

    /// Ensure the selected model is downloaded and loaded into memory.
    /// If already loaded with the same model, returns immediately (~0ms).
    @MainActor
    public func ensureLoaded(progress: @escaping (Double, String?) -> Void) async throws {
        // Fast path: model already loaded
        if let engine, engine.isLoaded, loadedModelId == selectedModelId {
            state = .ready
            return
        }

        // Different model selected — unload old one
        engine?.unload()
        engine = nil
        loadedModelId = nil

        guard let modelInfo = modelCatalog.first(where: { $0.variant == selectedModelId }) else {
            state = .error("Модель не найдена: \(selectedModelId)")
            throw ModelManagerError.modelNotFound(selectedModelId)
        }

        let newEngine = makeEngine(for: modelInfo)
        let variant = whisperVariant(for: selectedModelId)

        state = .downloading(progress: 0, detail: nil)

        do {
            try await newEngine.loadModel(variant: variant) { frac, detail in
                Task { @MainActor in
                    if frac < 1.0 {
                        self.state = .downloading(progress: frac, detail: detail)
                    } else {
                        self.state = .loading
                    }
                    progress(frac, detail)
                }
            }

            engine = newEngine
            loadedModelId = selectedModelId
            state = .ready
            modelStates[selectedModelId] = .loadedInMemory
            print("[ModelManager] Model loaded: \(selectedModelId)")
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Transcribe audio using the loaded model.
    /// Call `ensureLoaded()` first.
    public func transcribe(audioPath: String) async throws -> [ASRSegment] {
        guard let engine, engine.isLoaded else {
            throw ModelManagerError.modelNotLoaded
        }
        return try await engine.transcribe(audioPath: audioPath, language: selectedLanguage)
    }

    /// Unload the model from memory (free RAM).
    @MainActor
    public func unload() {
        if let loadedId = loadedModelId {
            modelStates[loadedId] = .downloaded
        }
        engine?.unload()
        engine = nil
        loadedModelId = nil
        if state == .ready {
            state = .idle
        }
        print("[ModelManager] Model unloaded")
    }

    // MARK: - Background Download / Delete

    /// Download a model in the background (without loading into memory)
    @MainActor
    public func downloadModelInBackground(variant: String) {
        guard let modelInfo = modelCatalog.first(where: { $0.variant == variant }) else { return }
        guard downloadState(for: variant) == .notDownloaded else { return }

        modelStates[variant] = .downloading(progress: 0, detail: nil)

        downloadTask = Task {
            do {
                switch modelInfo.engineType {
                case .whisperKit:
                    let whisperVariant = self.whisperVariant(for: variant)
                    _ = try await WhisperKitEngine.downloadOnly(variant: whisperVariant) { frac, detail in
                        Task { @MainActor in
                            self.modelStates[variant] = .downloading(progress: frac, detail: detail)
                        }
                    }
                case .parakeet:
                    _ = try await ParakeetEngine.downloadOnly { frac, detail in
                        Task { @MainActor in
                            self.modelStates[variant] = .downloading(progress: frac, detail: detail)
                        }
                    }
                }
                await MainActor.run {
                    self.modelStates[variant] = .downloaded
                }
                print("[ModelManager] Background download complete: \(variant)")
            } catch {
                await MainActor.run {
                    self.modelStates[variant] = .notDownloaded
                }
                print("[ModelManager] Background download failed: \(error)")
            }
        }
    }

    /// Delete a downloaded model from disk
    @MainActor
    public func deleteModel(variant: String) {
        guard let modelInfo = modelCatalog.first(where: { $0.variant == variant }) else { return }

        // Unload if currently loaded
        if loadedModelId == variant {
            unload()
        }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first

        switch modelInfo.engineType {
        case .whisperKit:
            let whisperVariant = self.whisperVariant(for: variant)
            let hfHub = cacheDir?.appendingPathComponent("huggingface/hub/models--argmaxinc--whisperkit-coreml")
            if let hfHub, let snapshots = try? FileManager.default.contentsOfDirectory(at: hfHub.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil) {
                for snapshot in snapshots {
                    let variantDir = snapshot.appendingPathComponent("openai_whisper-\(whisperVariant)")
                    if FileManager.default.fileExists(atPath: variantDir.path) {
                        try? FileManager.default.removeItem(at: variantDir)
                    }
                }
            }
        case .parakeet:
            let fluidDir = cacheDir?.appendingPathComponent("FluidAudio")
            if let fluidDir {
                try? FileManager.default.removeItem(at: fluidDir)
            }
        }

        modelStates[variant] = .notDownloaded
        print("[ModelManager] Deleted model: \(variant)")
    }

    // MARK: - Cache Cleanup

    /// Calculate total cache size (models + CoreML compiled cache + temp files)
    @MainActor
    public func cacheSize() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default

        // 1. FluidAudio models (Application Support)
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let fluidModels = appSupport.appendingPathComponent("FluidAudio")
            total += directorySize(fluidModels)
        }

        // 2. HuggingFace cache (WhisperKit models)
        if let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let hfHub = cacheDir.appendingPathComponent("huggingface")
            total += directorySize(hfHub)

            // 3. CoreML compiled model cache (e5rt) — can be HUGE
            if let bundleId = Bundle.main.bundleIdentifier {
                let e5rt = cacheDir.appendingPathComponent("\(bundleId)/com.apple.e5rt.e5bundlecache")
                total += directorySize(e5rt)
            }
        }

        // 4. Temp directory (leftovers)
        let tmpDir = fm.temporaryDirectory
        total += directorySize(tmpDir)

        return total
    }

    /// Clear all caches: CoreML compiled cache, temp files, and optionally models
    @MainActor
    public func clearCache(includeModels: Bool = false) {
        let fm = FileManager.default

        // 1. CoreML compiled cache (safe to delete — will be regenerated)
        if let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let bundleId = Bundle.main.bundleIdentifier {
            let e5rt = cacheDir.appendingPathComponent("\(bundleId)/com.apple.e5rt.e5bundlecache")
            try? fm.removeItem(at: e5rt)
            print("[ModelManager] Cleared CoreML compiled cache")
        }

        // 2. Temp directory — remove ALL mp4 files and silencecut_ files
        let tmpDir = fm.temporaryDirectory
        if let contents = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: [.fileSizeKey]) {
            var cleaned: Int64 = 0
            for file in contents {
                let name = file.lastPathComponent
                let isOurs = name.hasPrefix("silencecut_") || name.hasSuffix("_edited.mp4") || name.hasSuffix(".mp4")
                if isOurs {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    cleaned += Int64(size)
                    try? fm.removeItem(at: file)
                }
            }
            print("[ModelManager] Cleared temp files: \(Self.formatBytes(cleaned))")
        }

        // 3. Optionally delete all models
        if includeModels {
            unload()
            for model in modelCatalog {
                deleteModel(variant: model.variant)
            }
            print("[ModelManager] Deleted all models")
        }
    }

    /// Format bytes to human-readable string
    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f ГБ", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.0f МБ", Double(bytes) / 1_048_576)
        } else {
            return String(format: "%.0f КБ", Double(bytes) / 1024)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - App Lifecycle

    /// Call when app enters background. Starts 2-min timer to unload model.
    @MainActor
    public func onAppEnteredBackground() {
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: Self.backgroundTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.unload()
            }
        }
        print("[ModelManager] Background timer started (\(Self.backgroundTimeout)s)")
    }

    /// Call when app returns to foreground. Cancels unload timer.
    @MainActor
    public func onAppEnteredForeground() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        print("[ModelManager] Background timer cancelled")
    }

    // MARK: - Errors

    public enum ModelManagerError: Error, LocalizedError {
        case modelNotFound(String)
        case modelNotLoaded

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let id): return "Модель не найдена: \(id)"
            case .modelNotLoaded: return "Модель не загружена"
            }
        }
    }
}
