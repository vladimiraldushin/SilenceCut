import SwiftUI
import AVFoundation
import CoreMedia
import RECore

/// Main editor window — split view with preview, inspector, and timeline placeholder
public struct MainEditorView: View {
    @Bindable var viewModel: EditorViewModel

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            if viewModel.project.sourceURL != nil {
                HSplitView {
                    // Video Preview
                    VStack {
                        PreviewPlayerView(player: viewModel.player)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(8)

                        // Transport controls
                        HStack(spacing: 16) {
                            Button { viewModel.seekSmoothly(to: .zero) } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            Button { viewModel.togglePlayback() } label: {
                                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                            }
                            Text(formatTime(viewModel.playheadPosition))
                                .font(.system(.body, design: .monospaced))
                            Text("/ \(formatTime(viewModel.timeline.duration))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                    }
                    .frame(minWidth: 300)

                    // Inspector (clips list)
                    inspector
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                }

                Divider()

                // Timeline
                timelineView
                    .frame(height: 130)
            } else {
                dropZone
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onKeyPress(.space) {
            viewModel.togglePlayback()
            return .handled
        }
        .onKeyPress(.delete) {
            viewModel.deleteSelectedClip()
            return .handled
        }
        .focusable()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { openFile() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            Button { viewModel.splitAtPlayhead() } label: {
                Label("Split", systemImage: "scissors")
            }
            .disabled(viewModel.timeline.clips.isEmpty)
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button { viewModel.detectSilence() } label: {
                Label("Detect Silence", systemImage: "waveform.badge.minus")
            }
            .disabled(viewModel.project.sourceURL == nil || viewModel.isDetectingSilence)

            Spacer()

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(viewModel.timeline.enabledClipCount) clips")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            // Silence Detection Panel
            SilenceDetectionPanel(viewModel: viewModel)

            Divider()

            Text("Clips")
                .font(.headline)
                .padding()

            Divider()

            if viewModel.timeline.clips.isEmpty {
                VStack {
                    Spacer()
                    Text("No clips").foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.timeline.clips) { clip in
                            clipRow(clip)
                        }
                    }
                    .padding(8)
                }
            }
        }
        } // ScrollView
        .background(.background)
    }

    private func clipRow(_ clip: TimelineClip) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(clip.isEnabled ? Color.green : Color.red.opacity(0.5))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.isEnabled ? "Enabled" : "Disabled")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(formatTime(clip.sourceRange.start)) — \(formatTime(CMTimeRangeGetEnd(clip.sourceRange)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(formatDuration(clip.effectiveDuration))
                .font(.caption)
                .monospacedDigit()

            Button { viewModel.toggleClip(id: clip.id) } label: {
                Image(systemName: clip.isEnabled ? "eye" : "eye.slash")
            }.buttonStyle(.plain)

            Button { viewModel.deleteClip(id: clip.id) } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
    }

    // MARK: - Timeline

    private var timelineView: some View {
        VStack(spacing: 0) {
            // Transport bar
            HStack(spacing: 8) {
                Text(formatTime(viewModel.playheadPosition))
                    .font(.system(.caption, design: .monospaced))
                Text("/ \(formatTime(viewModel.timeline.duration))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { viewModel.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).font(.caption)
                Text("\(Int(viewModel.pixelsPerSecond))px/s")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button { viewModel.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            // Timeline canvas
            TimelineViewWrapper(
                clips: viewModel.timeline.clips,
                playheadPosition: viewModel.playheadPosition,
                pixelsPerSecond: viewModel.pixelsPerSecond,
                waveformData: viewModel.waveformData,
                onSeek: { time in viewModel.seekSmoothly(to: time) },
                onTrimClip: { id, range in viewModel.trimClip(id: id, newSourceRange: range) },
                onSelectClip: { id in viewModel.selectedClipId = id }
            )
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Drop a video file here")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("or click Import")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importVideo(url: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in viewModel.importVideo(url: url) }
        }
        return true
    }

    // MARK: - Formatting

    private func formatTime(_ time: CMTime) -> String {
        let s = CMTimeGetSeconds(time)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let fr = Int((s.truncatingRemainder(dividingBy: 1)) * 30)
        return String(format: "%02d:%02d:%02d", m, sec, fr)
    }

    private func formatDuration(_ time: CMTime) -> String {
        let s = CMTimeGetSeconds(time)
        return s < 1 ? String(format: "%.0fms", s * 1000) : String(format: "%.1fs", s)
    }
}
