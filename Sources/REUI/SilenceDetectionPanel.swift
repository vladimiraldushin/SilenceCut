import SwiftUI
import REAudioAnalysis

/// Side panel for silence detection settings and controls
struct SilenceDetectionPanel: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Silence Detection")
                .font(.headline)

            // Results summary
            if let result = viewModel.silenceResult {
                HStack(spacing: 16) {
                    Label("\(result.pauseCount) pauses", systemImage: "waveform.badge.minus")
                        .foregroundColor(.orange)
                    Label(String(format: "%.1fs saved", result.totalSilenceDuration),
                          systemImage: "clock.arrow.circlepath")
                        .foregroundColor(.green)
                }
                .font(.caption)
            }

            Divider()

            // Threshold slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Threshold")
                    Spacer()
                    Text("\(Int(viewModel.silenceSettings.thresholdDB)) dB")
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(viewModel.silenceSettings.thresholdDB) },
                    set: { viewModel.silenceSettings.thresholdDB = Float($0) }
                ), in: -60...(-15), step: 1)
                HStack {
                    Text("More silence").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text("Less silence").font(.caption2).foregroundColor(.secondary)
                }
            }

            // Min duration slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min Duration")
                    Spacer()
                    Text(String(format: "%.1fs", viewModel.silenceSettings.minSilenceDuration))
                        .foregroundColor(.secondary)
                }
                Slider(value: $viewModel.silenceSettings.minSilenceDuration, in: 0.1...2.0, step: 0.1)
            }

            // Padding slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Padding")
                    Spacer()
                    Text("\(Int(viewModel.silenceSettings.padding * 1000)) ms")
                        .foregroundColor(.secondary)
                }
                Slider(value: $viewModel.silenceSettings.padding, in: 0.05...0.5, step: 0.05)
            }

            Divider()

            // Presets
            HStack(spacing: 8) {
                Text("Preset:").font(.caption)
                Button("Aggressive") {
                    viewModel.silenceSettings = .aggressive
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Normal") {
                    viewModel.silenceSettings = .normal
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Conservative") {
                    viewModel.silenceSettings = .conservative
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Action buttons
            if viewModel.isDetectingSilence {
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.detectionProgress)
                    Text("Detecting silence...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button {
                    viewModel.detectSilence()
                } label: {
                    Label("Detect Silence", systemImage: "waveform.badge.minus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.project.sourceURL == nil)

                if viewModel.silenceResult != nil {
                    Button {
                        viewModel.restoreOriginal()
                    } label: {
                        Label("Restore Original", systemImage: "arrow.uturn.backward")
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
