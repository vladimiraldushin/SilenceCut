import SwiftUI
import AVKit

struct MainEditorView: View {
    @Bindable var project: EditProject
    @Bindable var engine: TimelineEngine

    @State private var player: AVPlayer?
    @State private var isDetecting = false
    @State private var detectionProgress: Double = 0
    @State private var waveformData: WaveformGenerator.WaveformData?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showExportPanel = false
    @State private var statusMessage: String = ""

    private let silenceDetector = SilenceDetector()
    private let waveformGenerator = WaveformGenerator()
    private let videoExporter = VideoExporter()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            if project.sourceURL != nil {
                HSplitView {
                    videoPreview.frame(minWidth: 300)
                    rightPanel.frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                }
                .frame(minHeight: 300)

                Divider()

                TimelineContainerView(
                    engine: engine,
                    waveformData: waveformData,
                    player: player,
                    sourceDuration: project.sourceDuration
                )
                .frame(minHeight: 120, idealHeight: 160)
            } else {
                dropZone
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
        .onChange(of: project.sourceURL) { _, newURL in
            if let url = newURL { loadVideo(url: url) }
        }
        // No composition-based playback — player plays source file directly
        // Silence skipping is handled by the time observer in TimelineContainerView
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showExportPanel) {
            ExportPanelView(
                project: project,
                engine: engine,
                exporter: videoExporter,
                isExporting: $isExporting,
                exportProgress: $exportProgress
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { openFile() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            Divider().frame(height: 20)

            Button { Task { await detectSilence() } } label: {
                Label("Detect Silence", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(project.sourceURL == nil || isDetecting)

            if isDetecting {
                ProgressView(value: detectionProgress).frame(width: 100)
                Text("\(Int(detectionProgress * 100))%").font(.caption).monospacedDigit()
            }

            if !statusMessage.isEmpty && !isDetecting {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }

            Divider().frame(height: 20)

            Button { engine.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }.disabled(!engine.canUndo)

            Button { engine.redo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }.disabled(!engine.canRedo)

            Spacer()

            if project.silenceDetected {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Saved: \(formatTime(engine.timeSaved))")
                        .font(.caption).foregroundStyle(.green)
                    Text("Export: \(formatTime(engine.totalDuration)) / \(formatTime(project.sourceDuration))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button { showExportPanel = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }.disabled(engine.fragments.isEmpty)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Video Preview

    private var videoPreview: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(9.0/16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            } else {
                Color.black
                    .aspectRatio(9.0/16.0, contentMode: .fit)
                    .overlay { Text("No video loaded").foregroundStyle(.secondary) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            }
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            SilenceDetectionPanelView(
                settings: $project.silenceSettings,
                isDetecting: isDetecting,
                silenceCount: engine.silenceCount,
                timeSaved: engine.timeSaved,
                onDetect: { Task { await detectSilence() } },
                onRemoveAll: { engine.removeAllSilence() },
                onRestoreAll: { engine.restoreAllSilence() }
            ).padding()

            Divider()

            FragmentListView(engine: engine, player: player)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack").font(.system(size: 64)).foregroundStyle(.tertiary)
            Text("Drop a video file here").font(.title2).foregroundStyle(.secondary)
            Text("or press Cmd+O to open").font(.subheadline).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            project.sourceURL = url
        }
    }

    private func loadVideo(url: URL) {
        print("[SilenceCut] Loading video: \(url.path)")

        // Fix #4: Don't call startAccessingSecurityScopedResource —
        // it doesn't help with ad-hoc signing and may cause resource leaks.
        // err=-12860 is a non-fatal warning, video plays despite it.
        let item = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }

        Task {
            let asset = AVAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let secs = CMTimeGetSeconds(duration)
                project.sourceDuration = secs
                engine.setSource(url: url, duration: secs)
                print("[SilenceCut] Video duration: \(secs)s")
                statusMessage = "Loaded: \(formatTime(secs))"
            } catch {
                print("[SilenceCut] ERROR: \(error)")
                statusMessage = "Error loading video"
            }
        }
    }

    private func detectSilence() async {
        guard let url = project.sourceURL else { return }

        print("[SilenceCut] === STARTING DETECTION ===")
        statusMessage = "Detecting..."
        isDetecting = true
        detectionProgress = 0

        do {
            let asset = AVAsset(url: url)

            let result = try await silenceDetector.detectSilence(
                in: asset,
                settings: project.silenceSettings
            ) { progress in
                Task { @MainActor in detectionProgress = progress }
            }

            print("[SilenceCut] === COMPLETE: \(result.fragments.count) fragments, \(result.silenceCount) silence ===")

            engine.loadFragments(result.fragments)
            project.silenceDetected = true
            statusMessage = "\(result.fragments.count) fragments (\(result.silenceCount) silence)"

            // Generate waveform
            waveformData = try await waveformGenerator.generateWaveform(from: asset)
            print("[SilenceCut] Waveform: \(waveformData?.samples.count ?? 0) samples")

            // Fix #4: Don't recreate player — it invalidates time observers
            // and causes more err=-12860. The player still works fine.

        } catch {
            print("[SilenceCut] ERROR: \(error)")
            errorMessage = error.localizedDescription
            showError = true
            statusMessage = "Failed"
        }

        isDetecting = false
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in project.sourceURL = url }
        }
        return true
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
