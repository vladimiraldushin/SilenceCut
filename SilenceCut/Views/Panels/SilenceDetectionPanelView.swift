import SwiftUI

struct SilenceDetectionPanelView: View {
    @Binding var settings: SilenceDetectionSettings
    let isDetecting: Bool
    let silenceCount: Int
    let timeSaved: Double
    let onDetect: () -> Void
    let onRemoveAll: () -> Void
    let onRestoreAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Silence Detection")
                .font(.headline)

            // Stats
            if silenceCount > 0 {
                HStack(spacing: 16) {
                    Label("\(silenceCount) pauses", systemImage: "waveform.badge.minus")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Label(formatTime(timeSaved) + " saved", systemImage: "clock.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            // Threshold slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Threshold")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(settings.thresholdDB)) dB")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.thresholdDB, in: -60...(-10), step: 1)
                HStack {
                    Text("More silence").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("Less silence").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            // Min duration slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min Duration")
                        .font(.subheadline)
                    Spacer()
                    Text("\(String(format: "%.1f", settings.minDurationSec))s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.minDurationSec, in: 0.1...2.0, step: 0.1)
            }

            // Padding slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Padding")
                        .font(.subheadline)
                    Spacer()
                    Text("\(settings.paddingMs) ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.paddingMs) },
                    set: { settings.paddingMs = Int($0) }
                ), in: 0...500, step: 10)
            }

            // Presets
            HStack(spacing: 8) {
                Text("Preset:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Aggressive") { withAnimation { settings = .aggressive } }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Normal") { withAnimation { settings = .normal } }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Conservative") { withAnimation { settings = .conservative } }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Divider()

            // Action buttons
            VStack(spacing: 8) {
                Button(action: onDetect) {
                    Label(
                        isDetecting ? "Detecting..." : "Detect Silence",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDetecting)

                HStack(spacing: 8) {
                    Button(action: onRemoveAll) {
                        Label("Remove All Silence", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onRestoreAll) {
                        Label("Restore All", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
