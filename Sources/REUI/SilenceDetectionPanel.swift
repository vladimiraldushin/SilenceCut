import SwiftUI
import REAudioAnalysis

/// Панель настроек детекции тишины
struct SilenceDetectionPanel: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Детекция тишины")
                .font(.headline)

            // Результаты
            if let result = viewModel.silenceResult {
                HStack(spacing: 16) {
                    Label("Пауз: \(result.pauseCount)", systemImage: "waveform.badge.minus")
                        .foregroundColor(.orange)
                    Label(String(format: "Сохранено: %.1f с", result.totalSilenceDuration),
                          systemImage: "clock.arrow.circlepath")
                        .foregroundColor(.green)
                }
                .font(.caption)
            }

            Divider()

            // Порог
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Порог")
                    Spacer()
                    Text("\(Int(viewModel.silenceSettings.thresholdDB)) дБ")
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(viewModel.silenceSettings.thresholdDB) },
                    set: { viewModel.silenceSettings.thresholdDB = Float($0) }
                ), in: -60...(-15), step: 1)
                HStack {
                    Text("Больше тишины").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text("Меньше тишины").font(.caption2).foregroundColor(.secondary)
                }
            }

            // Мин. длительность
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Мин. длительность")
                    Spacer()
                    Text(String(format: "%.1f с", viewModel.silenceSettings.minSilenceDuration))
                        .foregroundColor(.secondary)
                }
                Slider(value: $viewModel.silenceSettings.minSilenceDuration, in: 0.1...2.0, step: 0.1)
            }

            // Отступ
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Отступ")
                    Spacer()
                    Text("\(Int(viewModel.silenceSettings.padding * 1000)) мс")
                        .foregroundColor(.secondary)
                }
                Slider(value: $viewModel.silenceSettings.padding, in: 0.05...0.5, step: 0.05)
            }

            Divider()

            // Пресеты
            HStack(spacing: 8) {
                Text("Пресет:").font(.caption)
                Button("Жёсткий") {
                    viewModel.silenceSettings = .aggressive
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Обычный") {
                    viewModel.silenceSettings = .normal
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Мягкий") {
                    viewModel.silenceSettings = .conservative
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Кнопки действий
            if viewModel.isDetectingSilence {
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.detectionProgress)
                    Text("Поиск пауз...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button {
                    viewModel.detectSilence()
                } label: {
                    Label("Найти паузы", systemImage: "waveform.badge.minus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.project.sourceURL == nil)

                if viewModel.silenceResult != nil {
                    Button {
                        viewModel.restoreOriginal()
                    } label: {
                        Label("Восстановить оригинал", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
        .padding()
    }
}
