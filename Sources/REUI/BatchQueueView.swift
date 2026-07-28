#if os(macOS)
import SwiftUI
import AppKit
import RECore
import REAudioAnalysis
import REExport

/// Панель пакетной обработки: список видео, один сценарий (паузы → субтитры → экспорт)
/// прогоняется по очереди для всех файлов. Только macOS — на iOS нет произвольного выбора
/// папки назначения через NSOpenPanel, поэтому такого сценария там нет.
public struct BatchQueueView: View {
    @Bindable var model: BatchQueueModel
    let modelManager: ModelManager

    public init(model: BatchQueueModel, modelManager: ModelManager) {
        self.model = model
        self.modelManager = modelManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пакетная обработка")
                .font(.headline)

            fileControls
            Divider()
            settingsSection
            Divider()

            if model.jobs.isEmpty {
                emptyState
            } else {
                jobsList
            }

            Divider()
            bottomBar
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - File Controls

    private var fileControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    addFiles()
                } label: {
                    Label("Добавить файлы...", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    chooseOutputDirectory()
                } label: {
                    Label("Папка назначения...", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            HStack(spacing: 4) {
                Text("Папка:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.outputDirectory?.path ?? "не выбрана")
                    .font(.caption)
                    .foregroundStyle(model.outputDirectory == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Качество:")
                        .font(.caption)
                    Picker("", selection: $model.exportPreset) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(preset.description).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                HStack(spacing: 4) {
                    Text("Кадр:")
                        .font(.caption)
                    Picker("", selection: $model.renderOptions.outputAspect) {
                        ForEach(OutputAspect.allCases) { aspect in
                            Text(aspect.displayName).tag(aspect)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }

                Spacer()
            }

            HStack(spacing: 16) {
                Toggle("Джамп-кат зум", isOn: $model.renderOptions.jumpCutZoomEnabled)
                Toggle("Транскрибировать", isOn: $model.transcribeEnabled)
                Toggle("Вжигать субтитры", isOn: $model.burnSubtitles)
                    .disabled(!model.transcribeEnabled)
            }
            .font(.caption)
            .controlSize(.small)
        }
    }

    // MARK: - Jobs List

    private var jobsList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.jobs) { job in
                    jobRow(job)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func jobRow(_ job: BatchJob) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusView(job.state)
            }
            Spacer()
            if !isRunningState(job.state) {
                Button {
                    model.removeJob(id: job.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func statusView(_ state: BatchJob.State) -> some View {
        switch state {
        case .pending:
            Text("Ожидание")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .running(let stage, let progress):
            HStack(spacing: 6) {
                ProgressView(value: max(0, min(1, progress)))
                    .frame(width: 140)
                Text("\(stage) · \(Int(max(0, min(1, progress)) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .done(_, let removedSeconds):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(format: "−%.1f с пауз", removedSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

        case .cancelled:
            Text("Отменено")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isRunningState(_ state: BatchJob.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Перетащите файлы или нажмите «Добавить файлы»")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView(value: model.overallProgress)
                Text(model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            HStack {
                Button {
                    model.clearFinished()
                } label: {
                    Label("Очистить завершённые", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.jobs.isEmpty)

                Spacer()

                if model.isRunning {
                    Button {
                        model.cancel()
                    } label: {
                        Label("Отменить", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        model.start(modelManager: modelManager)
                    } label: {
                        Label("Старт", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.jobs.isEmpty || model.outputDirectory == nil)
                }
            }
        }
    }

    // MARK: - Actions

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            model.addFiles(panel.urls)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    model.addFiles([url])
                }
            }
        }
        return true
    }
}

#endif
