import SwiftUI
import CoreMedia
import RECore

/// Inspector panel for subtitle management and styling
struct SubtitlePanel: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subtitles")
                .font(.headline)

            // Transcribe button / progress
            if viewModel.isTranscribing {
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.transcriptionProgress)
                    Text(viewModel.transcriptionPhase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button {
                    viewModel.transcribe()
                } label: {
                    Label("Transcribe", systemImage: "text.word.spacing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.project.sourceURL == nil)
            }

            if !viewModel.subtitleEntries.isEmpty {
                Divider()

                // Style preset picker
                HStack {
                    Text("Style:")
                    Picker("", selection: Binding(
                        get: { viewModel.subtitleStyle.preset },
                        set: { viewModel.subtitleStyle = SubtitleStyle.forPreset($0) }
                    )) {
                        ForEach(SubtitlePreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Show/hide toggle
                Toggle("Show subtitles", isOn: $viewModel.showSubtitles)
                    .font(.caption)

                // Position
                Picker("Position", selection: $viewModel.subtitleStyle.position) {
                    Text("Top").tag(SubtitlePosition.top)
                    Text("Center").tag(SubtitlePosition.center)
                    Text("Bottom").tag(SubtitlePosition.bottom)
                }
                .pickerStyle(.segmented)

                // Font size
                HStack {
                    Text("Size")
                    Slider(value: $viewModel.subtitleStyle.fontSize, in: 32...72, step: 2)
                    Text("\(Int(viewModel.subtitleStyle.fontSize))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 30)
                }

                // Uppercase
                Toggle("UPPERCASE", isOn: $viewModel.subtitleStyle.isUppercase)
                    .font(.caption)

                Divider()

                // Subtitle list
                Text("\(viewModel.subtitleEntries.count) segments")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(viewModel.subtitleEntries.enumerated()), id: \.element.id) { index, entry in
                            subtitleRow(entry, index: index)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
    }

    private func subtitleRow(_ entry: SubtitleEntry, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(formatTime(entry.startTime))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .trailing)

            TextField("", text: Binding(
                get: { viewModel.subtitleEntries[safe: index]?.text ?? "" },
                set: { newText in
                    if index < viewModel.subtitleEntries.count {
                        viewModel.subtitleEntries[index].text = newText
                        // Re-split words from edited text
                        viewModel.updateSubtitleWords(at: index)
                    }
                }
            ))
            .font(.caption)
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                if let tlTime = viewModel.timeline.timelineTime(forSourceTime: entry.startTime) {
                    viewModel.seekSmoothly(to: tlTime)
                }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button {
                if index < viewModel.subtitleEntries.count {
                    viewModel.subtitleEntries.remove(at: index)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
    }

    private func formatTime(_ time: CMTime) -> String {
        let secs = CMTimeGetSeconds(time)
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        let ms = Int((secs - Double(Int(secs))) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }
}
