import SwiftUI
import REAudioAnalysis

/// Панель детекции тишины с режимом ревью: зоны показываются на таймлайне,
/// пользователь может исключить отдельные паузы и только потом применить.
struct SilenceDetectionPanel: View {
    @Bindable var viewModel: EditorViewModel

    private enum PresetChoice: String, CaseIterable, Identifiable {
        case aggressive = "Жёсткий"
        case normal = "Обычный"
        case conservative = "Мягкий"
        var id: String { rawValue }

        var settings: SilenceSettings {
            switch self {
            case .aggressive: return .aggressive
            case .normal: return .normal
            case .conservative: return .conservative
            }
        }
    }

    /// Активный пресет, если настройки совпадают с одним из них
    private var currentPreset: PresetChoice? {
        PresetChoice.allCases.first { $0.settings == viewModel.silenceSettings }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Детекция тишины")
                .font(.headline)

            // Результаты
            if let result = viewModel.silenceResult {
                HStack(spacing: 16) {
                    Label("Пауз: \(result.pauseCount)", systemImage: "waveform.badge.minus")
                        .foregroundColor(.orange)
                    Label(String(format: "−%.1f с", result.totalSilenceDuration),
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
                    set: {
                        viewModel.silenceSettings.thresholdDB = Float($0)
                        viewModel.recomputeReviewZones()
                    }
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
                Slider(value: Binding(
                    get: { viewModel.silenceSettings.minSilenceDuration },
                    set: {
                        viewModel.silenceSettings.minSilenceDuration = $0
                        viewModel.recomputeReviewZones()
                    }
                ), in: 0.1...2.0, step: 0.1)
            }

            // Отступ
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Отступ")
                    Spacer()
                    Text("\(Int(viewModel.silenceSettings.padding * 1000)) мс")
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { viewModel.silenceSettings.padding },
                    set: {
                        viewModel.silenceSettings.padding = $0
                        viewModel.recomputeReviewZones()
                    }
                ), in: 0.05...0.5, step: 0.05)
            }

            // Пресеты — сегментированный пикер с подсветкой активного
            Picker("", selection: Binding(
                get: { currentPreset },
                set: { choice in
                    if let choice {
                        viewModel.silenceSettings = choice.settings
                        viewModel.recomputeReviewZones()
                    }
                }
            )) {
                ForEach(PresetChoice.allCases) { preset in
                    Text(preset.rawValue).tag(Optional(preset))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            // Действия
            if viewModel.isDetectingSilence {
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.detectionProgress)
                    Text("Анализ аудио...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if viewModel.silenceReviewActive {
                // Режим ревью — зоны на таймлайне, применить/отменить
                let cutCount = viewModel.reviewZones.filter(\.willCut).count
                VStack(alignment: .leading, spacing: 8) {
                    Text("Клик по зоне на таймлайне — оставить/вырезать")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(isOn: $viewModel.skipSilencesInPreview) {
                        Label("Слушать с пропусками", systemImage: "forward.end")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Button {
                        viewModel.applySilenceReview()
                    } label: {
                        Label("Вырезать \(cutCount) пауз", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cutCount == 0)

                    Button {
                        viewModel.cancelSilenceReview()
                    } label: {
                        Text("Отмена")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    viewModel.enterSilenceReview()
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
