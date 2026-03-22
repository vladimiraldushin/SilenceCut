import SwiftUI

struct ExportPanelView: View {
    @Bindable var project: EditProject
    @Bindable var engine: TimelineEngine
    let exporter: VideoExporter
    @Binding var isExporting: Bool
    @Binding var exportProgress: Double
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Video")
                .font(.title2)
                .fontWeight(.semibold)

            // Stats
            VStack(spacing: 8) {
                HStack {
                    Text("Original duration:")
                    Spacer()
                    Text(formatTime(project.sourceDuration))
                        .monospacedDigit()
                }
                HStack {
                    Text("Export duration:")
                    Spacer()
                    Text(formatTime(engine.totalDuration))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                HStack {
                    Text("Time saved:")
                    Spacer()
                    Text(formatTime(engine.timeSaved))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("Fragments included:")
                    Spacer()
                    Text("\(engine.fragments.filter { $0.isIncluded }.count) / \(engine.fragments.count)")
                        .monospacedDigit()
                }
            }
            .font(.subheadline)

            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 12) {
                Picker("Quality:", selection: $project.exportSettings.preset) {
                    ForEach(ExportSettings.ExportPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }

                Picker("Format:", selection: $project.exportSettings.format) {
                    ForEach(ExportSettings.ExportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
            }

            if isExporting {
                VStack(spacing: 8) {
                    ProgressView(value: exportProgress)
                    Text("Exporting... \(Int(exportProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Buttons
            HStack {
                Button("Cancel") {
                    if isExporting {
                        Task { await exporter.cancel() }
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export") {
                    Task { await startExport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func startExport() async {
        guard let sourceURL = project.sourceURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name)_edited.mp4"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExporting = true
        exportProgress = 0
        errorMessage = nil

        do {
            _ = try await exporter.export(
                sourceURL: sourceURL,
                fragments: engine.fragments,
                settings: project.exportSettings,
                outputURL: outputURL
            ) { progress in
                Task { @MainActor in
                    exportProgress = progress.progress
                }
            }

            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
