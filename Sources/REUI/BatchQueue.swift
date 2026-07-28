import Foundation
import AVFoundation
import CoreMedia
import RECore
import REAudioAnalysis
import REExport

/// Один элемент очереди пакетной обработки — исходный файл и текущее состояние конвейера.
public struct BatchJob: Identifiable, Equatable {
    public enum State: Equatable {
        case pending
        case running(stage: String, progress: Double)   // stage: "Анализ", "Субтитры", "Экспорт"
        case done(outputURL: URL, removedSeconds: Double)
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let sourceURL: URL
    public var state: State

    public init(id: UUID = UUID(), sourceURL: URL, state: State = .pending) {
        self.id = id
        self.sourceURL = sourceURL
        self.state = state
    }
}

/// Пакетная обработка: один и тот же сценарий (вырезать паузы → опционально субтитры →
/// экспорт) прогоняется последовательно по списку видеофайлов. Задачи обрабатываются строго
/// одна за другой — ASR-модель и кодек не терпят параллельной работы.
@Observable
public final class BatchQueueModel {
    public var jobs: [BatchJob] = []
    public var outputDirectory: URL?
    public var silenceSettings: SilenceSettings = .normal
    public var exportPreset: ExportPreset = .high
    public var renderOptions: RenderOptions = .default
    public var subtitleStyle: SubtitleStyle = .classic
    public var transcribeEnabled: Bool = false
    public var burnSubtitles: Bool = true          // вжигать в кадр (иначе только .srt/.md рядом)
    public private(set) var isRunning: Bool = false
    public private(set) var currentJobIndex: Int?

    /// ID задачи, которая выполняется прямо сейчас — источник истины, currentJobIndex
    /// пересчитывается из него после любого изменения массива jobs
    private var currentJobID: UUID?
    private var cancellationToken: ExportCancellationToken?
    private var runTask: Task<Void, Never>?

    public init() {}

    // MARK: - Queue Management

    /// Добавляет файлы, игнорируя дубликаты по sourceURL
    public func addFiles(_ urls: [URL]) {
        for url in urls {
            guard !jobs.contains(where: { $0.sourceURL == url }) else { continue }
            jobs.append(BatchJob(sourceURL: url))
        }
    }

    /// Удаляет задачу из очереди; нельзя удалить ту, что выполняется прямо сейчас
    public func removeJob(id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        if isRunning, jobs[idx].id == currentJobID { return }
        jobs.remove(at: idx)
        resyncCurrentJobIndex()
    }

    /// Убирает из списка все завершённые задачи (готово / ошибка / отменено)
    public func clearFinished() {
        jobs.removeAll { job in
            switch job.state {
            case .done, .failed, .cancelled: return true
            case .pending, .running: return false
            }
        }
        resyncCurrentJobIndex()
    }

    private func resyncCurrentJobIndex() {
        guard let currentJobID else {
            currentJobIndex = nil
            return
        }
        currentJobIndex = jobs.firstIndex(where: { $0.id == currentJobID })
    }

    // MARK: - Run Control

    /// Запускает последовательную обработку всех задач в состоянии .pending
    public func start(modelManager: ModelManager) {
        guard !isRunning else { return }
        guard outputDirectory != nil else { return }
        let idsToProcess = jobs.filter { isPending($0.state) }.map(\.id)
        guard !idsToProcess.isEmpty else { return }

        isRunning = true
        let token = ExportCancellationToken()
        cancellationToken = token

        runTask = Task { @MainActor in
            for jobID in idsToProcess {
                guard !token.isCancelled else { break }
                guard let idx = self.jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                guard self.isPending(self.jobs[idx].state) else { continue }

                self.currentJobID = jobID
                self.currentJobIndex = idx
                await self.runJob(id: jobID, modelManager: modelManager, token: token)
            }

            // Всё, что осталось в .pending (не успело начаться до отмены), тоже помечаем отменённым
            for i in self.jobs.indices where self.isPending(self.jobs[i].state) {
                self.jobs[i].state = .cancelled
            }

            self.isRunning = false
            self.currentJobIndex = nil
            self.currentJobID = nil
            self.cancellationToken = nil
        }
    }

    /// Отменяет текущий экспорт; остальные ожидающие задачи помечаются cancelled сразу
    public func cancel() {
        cancellationToken?.cancel()
        for i in jobs.indices where isPending(jobs[i].state) {
            if jobs[i].id != currentJobID {
                jobs[i].state = .cancelled
            }
        }
    }

    /// 0...1 по всем задачам — pending = 0, running = его прогресс, done/failed/cancelled = 1
    public var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let sum = jobs.reduce(0.0) { partial, job in
            switch job.state {
            case .pending: return partial
            case .running(_, let progress): return partial + max(0, min(1, progress))
            case .done, .failed, .cancelled: return partial + 1.0
            }
        }
        return sum / Double(jobs.count)
    }

    /// «Готово N из M»
    public var summary: String {
        let done = jobs.filter {
            if case .done = $0.state { return true }
            return false
        }.count
        return "Готово \(done) из \(jobs.count)"
    }

    private func isPending(_ state: BatchJob.State) -> Bool {
        if case .pending = state { return true }
        return false
    }

    // MARK: - Pipeline (Анализ → Субтитры → Экспорт)

    @MainActor
    private func runJob(id: UUID, modelManager: ModelManager, token: ExportCancellationToken) async {
        guard let sourceURL = jobs.first(where: { $0.id == id })?.sourceURL else { return }
        guard !token.isCancelled else {
            updateState(id: id, .cancelled)
            return
        }
        guard let outDir = outputDirectory else {
            updateState(id: id, .failed("Не выбрана папка назначения"))
            return
        }

        // Снимок настроек на момент старта задачи — правки в UI во время прогона
        // не должны менять поведение уже начатой задачи
        let settings = silenceSettings
        let preset = exportPreset
        let options = renderOptions
        let style = subtitleStyle
        let doTranscribe = transcribeEnabled
        let doBurn = burnSubtitles

        updateState(id: id, .running(stage: "Анализ", progress: 0))

        do {
            // --- 1. Анализ: waveform+RMS → детекция тишины → длительность → таймлайн (0...0.15) ---
            let analysis = try await AudioAnalysis.analyze(url: sourceURL) { fraction in
                Task { @MainActor in
                    self.updateState(id: id, .running(stage: "Анализ", progress: fraction * 0.15))
                }
            }

            if token.isCancelled { updateState(id: id, .cancelled); return }

            let silence = SilenceDetector.detect(cache: analysis.rms, settings: settings)
            guard !silence.speechRanges.isEmpty else {
                updateState(id: id, .failed("Не найдено речи"))
                return
            }

            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration)
            let timeline = EditTimeline.fromSpeechRanges(
                silence.speechRanges,
                sourceURL: sourceURL,
                availableRange: CMTimeRange(start: .zero, duration: duration)
            )

            updateState(id: id, .running(stage: "Анализ", progress: 0.15))
            if token.isCancelled { updateState(id: id, .cancelled); return }

            // --- 2. Субтитры (опционально, 0.15...0.5) ---
            var subs: [SubtitleEntry] = []
            if doTranscribe {
                updateState(id: id, .running(stage: "Субтитры", progress: 0.15))
                let tempAudioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("silencecut_batch_\(UUID().uuidString).m4a")
                do {
                    try await ExportService.exportAudioOnly(
                        timeline: timeline,
                        to: tempAudioURL,
                        cancellation: token
                    ) { progress in
                        Task { @MainActor in
                            self.updateState(id: id, .running(stage: "Субтитры", progress: 0.15 + progress.fraction * 0.15))
                        }
                    }
                    subs = try await TranscriptionService.transcribe(
                        url: tempAudioURL,
                        modelManager: modelManager
                    ) { progress in
                        Task { @MainActor in
                            self.updateState(id: id, .running(stage: "Субтитры", progress: 0.3 + progress.fraction * 0.2))
                        }
                    }
                } catch {
                    // Ошибка транскрибации не должна ронять всю задачу — продолжаем без субтитров
                    print("[BatchQueue] Транскрибация не удалась для \(sourceURL.lastPathComponent): \(error)")
                    subs = []
                }
                try? FileManager.default.removeItem(at: tempAudioURL)
            }

            if token.isCancelled { updateState(id: id, .cancelled); return }

            // --- 3. Экспорт (до 1.0) ---
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let outputURL = outDir.appendingPathComponent("\(baseName)_edited.mp4")
            let exportStageStart = doTranscribe ? 0.5 : 0.15
            updateState(id: id, .running(stage: "Экспорт", progress: exportStageStart))

            try await ExportService.export(
                timeline: timeline,
                to: outputURL,
                preset: preset,
                subtitleEntries: doBurn ? subs : [],
                subtitleStyle: style,
                renderOptions: options,
                cancellation: token
            ) { progress in
                Task { @MainActor in
                    self.updateState(id: id, .running(
                        stage: "Экспорт",
                        progress: exportStageStart + progress.fraction * (1.0 - exportStageStart)
                    ))
                }
            }

            if !subs.isEmpty {
                _ = try? SubtitleMarkdownExporter.write(entries: subs, videoURL: outputURL, projectName: baseName)
                _ = try? SubtitleSRTExporter.writeSRT(entries: subs, videoURL: outputURL)
            }

            updateState(id: id, .done(outputURL: outputURL, removedSeconds: silence.totalSilenceDuration))
        } catch ExportService.ExportError.cancelled {
            updateState(id: id, .cancelled)
        } catch {
            updateState(id: id, .failed(error.localizedDescription))
        }
    }

    private func updateState(id: UUID, _ state: BatchJob.State) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].state = state
    }
}
