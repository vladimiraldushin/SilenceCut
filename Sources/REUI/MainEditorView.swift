import SwiftUI
import AVFoundation
import CoreMedia
import RECore
import REExport
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import PhotosUI
#endif

/// Main editor window — platform-adaptive layout
public struct MainEditorView: View {
    @Bindable var viewModel: EditorViewModel

    @State private var showExportConfirmation = false

    #if os(iOS)
    @State private var showImportPicker = false
    @State private var showInspectorSheet = false
    #endif

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        #if os(macOS)
        macOSBody
        #elseif os(iOS)
        iOSBody
        #endif
    }

    // MARK: - Formatting (shared)

    private func formatTime(_ time: CMTime) -> String {
        let s = CMTimeGetSeconds(time)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let fr = Int((s.truncatingRemainder(dividingBy: 1)) * 30)
        return String(format: "%02d:%02d:%02d", m, sec, fr)
    }

    private func formatDuration(_ time: CMTime) -> String {
        let s = CMTimeGetSeconds(time)
        return s < 1 ? String(format: "%.0f мс", s * 1000) : String(format: "%.1f с", s)
    }
}

// MARK: - macOS Layout
#if os(macOS)
extension MainEditorView {
    private var macOSBody: some View {
        VStack(spacing: 0) {
            macOSToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            if viewModel.project.sourceURL != nil {
                HSplitView {
                    // Video Preview
                    VStack {
                        PreviewPlayerView(player: viewModel.player)
                            .aspectRatio(viewModel.videoAspectRatio, contentMode: .fit)
                            .overlay {
                                GeometryReader { geo in
                                    let active = viewModel.activeSubtitle(at: viewModel.playheadPosition)
                                    SubtitleOverlayView(
                                        entry: active,
                                        activeWordIndex: active.flatMap {
                                            viewModel.activeWordIndex(in: $0, at: viewModel.playheadPosition)
                                        },
                                        style: viewModel.subtitleStyle,
                                        videoFrame: geo.size,
                                        showSafeZones: viewModel.showSafeZones
                                    )
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: .infinity)
                            .padding(8)

                        transportControls
                    }
                    .frame(minWidth: 300)

                    macOSInspector
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                }

                Divider()

                timelineSection
                    .frame(height: 130)

                statusBar
            } else {
                dropZone
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDropMacOS(providers)
        }
        .sheet(isPresented: $viewModel.showHotkeysHelp) {
            HotkeysHelpView()
        }
        // Space/Delete/JKL handled by the AppDelegate NSEvent monitor —
        // SwiftUI onKeyPress on an ancestor would swallow keys typed into text fields
    }

    /// Тонкий статус-бар: сообщения, автосейв, счётчики
    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let saved = viewModel.lastAutosaveAt {
                Label(saved.formatted(date: .omitted, time: .shortened), systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Проект автосохранён")
            }
            Text("\(viewModel.timeline.enabledClipCount) клипов")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var macOSToolbar: some View {
        HStack(spacing: 12) {
            Button { openFileMacOS() } label: {
                Label("Импорт", systemImage: "square.and.arrow.down")
            }

            Button { viewModel.splitAtPlayhead() } label: {
                Label("Разрезать", systemImage: "scissors")
            }
            .disabled(viewModel.timeline.clips.isEmpty)
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Spacer()

            Button {
                viewModel.showHotkeysHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("Горячие клавиши (?)")

            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                    .frame(width: 120)
                Text("\(Int(viewModel.exportProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                if !viewModel.exportRemainingText.isEmpty {
                    Text(viewModel.exportRemainingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Отменить") { viewModel.cancelExport() }
            } else {
                // Настройки экспорта (пресет, нарезка, субтитры) — в диалоге сохранения
                Button { viewModel.exportVideo() } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.timeline.clips.isEmpty)
            }
        }
        .buttonStyle(.bordered)
    }

    private var macOSInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SilenceDetectionPanel(viewModel: viewModel)
                Divider()
                SubtitlePanel(viewModel: viewModel)
                Divider()
                Text("Клипы").font(.headline).padding()
                Divider()

                if viewModel.timeline.clips.isEmpty {
                    VStack {
                        Spacer()
                        Text("Нет клипов").foregroundStyle(.tertiary)
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
        }
        .background(.background)
    }

    private func openFileMacOS() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importVideo(url: url)
        }
    }

    private func handleDropMacOS(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in viewModel.importVideo(url: url) }
        }
        return true
    }
}

/// Настройки экспорта — accessory view в NSSavePanel
public struct ExportOptionsView: View {
    @Bindable var viewModel: EditorViewModel

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Качество:")
                Picker("", selection: $viewModel.exportPreset) {
                    ForEach(ExportPreset.allCases) { preset in
                        Text(preset.description).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            Toggle("Вжигать субтитры (\(viewModel.subtitleEntries.count))", isOn: $viewModel.showSubtitles)
                .disabled(viewModel.subtitleEntries.isEmpty)

            HStack {
                Toggle("Нарезка на части", isOn: $viewModel.autoSplitEnabled)
                if viewModel.autoSplitEnabled {
                    Picker("", selection: $viewModel.autoSplitDuration) {
                        Text("30 с").tag(30.0)
                        Text("60 с").tag(60.0)
                        Text("90 с").tag(90.0)
                        Text("120 с").tag(120.0)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            Text("Рядом с видео сохранятся .md и .srt с субтитрами")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 380)
    }
}

/// Шпаргалка горячих клавиш (открывается по «?»)
struct HotkeysHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let keys: [(String, String)] = [
        ("Пробел", "Воспроизведение / пауза"),
        ("J / L", "Секунда назад / вперёд"),
        ("K", "Пауза"),
        ("← / →", "Кадр назад / вперёд"),
        ("[ / ]", "Предыдущая / следующая склейка"),
        ("I", "Обрезать начало клипа до плейхеда"),
        ("O", "Обрезать конец клипа от плейхеда"),
        ("⌘⇧S", "Разрезать клип"),
        ("Delete", "Удалить выбранный клип"),
        ("⌘Z / ⌘⇧Z", "Отменить / повторить"),
        ("⌘S", "Сохранить проект"),
        ("⌘O / ⌘⇧O", "Открыть видео / проект"),
        ("?", "Эта шпаргалка"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Горячие клавиши")
                .font(.headline)
                .padding(.bottom, 12)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(keys, id: \.0) { key, action in
                    GridRow {
                        Text(key)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(action)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 420)
    }
}
#endif

// MARK: - iOS Layout
#if os(iOS)
extension MainEditorView {
    private var iOSBody: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if viewModel.project.sourceURL != nil {
                        // Video Preview — the inspector opens as a sheet with detents,
                        // so the preview keeps its size
                        PreviewPlayerView(player: viewModel.player)
                            .aspectRatio(viewModel.videoAspectRatio, contentMode: .fit)
                            .overlay {
                                GeometryReader { geo in
                                    let active = viewModel.activeSubtitle(at: viewModel.playheadPosition)
                                    SubtitleOverlayView(
                                        entry: active,
                                        activeWordIndex: active.flatMap {
                                            viewModel.activeWordIndex(in: $0, at: viewModel.playheadPosition)
                                        },
                                        style: viewModel.subtitleStyle,
                                        videoFrame: geo.size,
                                        showSafeZones: viewModel.showSafeZones
                                    )
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 8)
                            .frame(maxHeight: .infinity)
                            .onTapGesture {
                                viewModel.togglePlayback()
                            }

                        // Transport controls
                        transportControls
                            .padding(.vertical, 4)

                        timelineSection
                            .frame(height: 120)

                        iOSBottomToolbar
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.bar)
                    } else {
                        iOSDropZone
                    }
                }
            }
            .overlay {
                if viewModel.isImporting {
                    ZStack {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text(viewModel.statusMessage)
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .padding(32)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .navigationTitle(viewModel.project.name.isEmpty ? "SilenceCut" : viewModel.project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showImportPicker = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if viewModel.project.sourceURL != nil {
                            Button {
                                showInspectorSheet.toggle()
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                        }
                        if viewModel.lastExportedURL != nil && !viewModel.isExporting {
                            Button { viewModel.saveExportToPhotos() } label: {
                                Image(systemName: "photo.badge.plus")
                            }
                        }
                        if viewModel.isExporting {
                            ProgressView(value: viewModel.exportProgress)
                                .frame(width: 60)
                            Button { viewModel.cancelExport() } label: {
                                Image(systemName: "xmark.circle")
                            }
                        } else {
                            Button { showExportConfirmation = true } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .disabled(viewModel.timeline.clips.isEmpty)
                        }
                    }
                }
            }
            .sheet(isPresented: $showExportConfirmation) {
                iOSExportOptions
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showInspectorSheet) {
                iOSInlineInspector
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .sheet(isPresented: $showImportPicker) {
                IOSVideoPicker(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showShareSheet) {
                ShareSheet(activityItems: viewModel.exportedShareItems)
            }
            .onKeyPress(.space) {
                guard !viewModel.isTextEditingActive else { return .ignored }
                viewModel.togglePlayback()
                return .handled
            }
            .onKeyPress(.delete) {
                guard !viewModel.isTextEditingActive else { return .ignored }
                viewModel.deleteSelectedClip()
                return .handled
            }
            .focusable()
        }
    }

    /// Настройки экспорта перед запуском (iOS)
    private var iOSExportOptions: some View {
        NavigationStack {
            Form {
                Picker("Качество", selection: $viewModel.exportPreset) {
                    ForEach(ExportPreset.allCases) { preset in
                        Text(preset.description).tag(preset)
                    }
                }
                Toggle("Вжигать субтитры (\(viewModel.subtitleEntries.count))", isOn: $viewModel.showSubtitles)
                    .disabled(viewModel.subtitleEntries.isEmpty)
                Toggle("Нарезка на части", isOn: $viewModel.autoSplitEnabled)
                if viewModel.autoSplitEnabled {
                    Picker("Длительность части", selection: $viewModel.autoSplitDuration) {
                        Text("30 с").tag(30.0)
                        Text("60 с").tag(60.0)
                        Text("90 с").tag(90.0)
                        Text("120 с").tag(120.0)
                    }
                }
                Section {
                    Button {
                        showExportConfirmation = false
                        viewModel.exportVideo()
                    } label: {
                        Label("Экспортировать", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Вместе с видео будут подготовлены .md и .srt с субтитрами")
                }
            }
            .navigationTitle("Экспорт")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var iOSBottomToolbar: some View {
        HStack(spacing: 16) {
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)

            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)

            Divider().frame(height: 24)

            Button { viewModel.splitAtPlayhead() } label: {
                Image(systemName: "scissors")
            }
            .disabled(viewModel.timeline.clips.isEmpty)

            Button { viewModel.deleteSelectedClip() } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.selectedClipId == nil)
            .foregroundStyle(.red)

            Spacer()

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("\(viewModel.timeline.enabledClipCount) клипов")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.title3)
    }

    private var iOSInlineInspector: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Настройки")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showInspectorSheet = false
                    }
                } label: {
                    Text("Готово")
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            // Scrollable settings
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SilenceDetectionPanel(viewModel: viewModel)
                    Divider()
                    SubtitlePanel(viewModel: viewModel)
                }
            }
        }
    }

    private var iOSDropZone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Нажмите Импорт для добавления видео")
                .font(.title2)
                .foregroundStyle(.secondary)
            Button { showImportPicker = true } label: {
                Label("Импорт видео", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - iOS Video Picker

struct IOSVideoPicker: UIViewControllerRepresentable {
    let viewModel: EditorViewModel

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let viewModel: EditorViewModel

        init(viewModel: EditorViewModel) {
            self.viewModel = viewModel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }

            // Сразу показываем индикатор загрузки
            Task { @MainActor in
                self.viewModel.isImporting = true
                self.viewModel.statusMessage = "Копирование видео..."
            }

            result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, error in
                guard let url else {
                    Task { @MainActor in
                        self.viewModel.isImporting = false
                        self.viewModel.statusMessage = ""
                    }
                    return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: url, to: dest)

                Task { @MainActor in
                    self.viewModel.importVideo(url: dest)
                }
            }
        }
    }
}

// MARK: - iOS Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Shared Components

extension MainEditorView {
    var transportControls: some View {
        HStack(spacing: 14) {
            Button { viewModel.seekSmoothly(to: .zero) } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("В начало")
            Button { viewModel.jumpToPreviousCut() } label: {
                Image(systemName: "chevron.backward.2")
            }
            .help("Предыдущая склейка [")
            Button { viewModel.nudgePlayhead(by: -1.0 / viewModel.videoFPS) } label: {
                Image(systemName: "backward.frame.fill")
            }
            .help("Кадр назад ←")
            Button { viewModel.togglePlayback() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .help("Пробел")
            Button { viewModel.nudgePlayhead(by: 1.0 / viewModel.videoFPS) } label: {
                Image(systemName: "forward.frame.fill")
            }
            .help("Кадр вперёд →")
            Button { viewModel.jumpToNextCut() } label: {
                Image(systemName: "chevron.forward.2")
            }
            .help("Следующая склейка ]")

            Text(formatTime(viewModel.playheadPosition))
                .font(.system(.body, design: .monospaced))
            Text("/ \(formatTime(viewModel.timeline.duration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    var timelineSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(formatTime(viewModel.playheadPosition))
                    .font(.system(.caption, design: .monospaced))
                Text("/ \(formatTime(viewModel.timeline.duration))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { viewModel.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).font(.caption)
                Text("\(Int(viewModel.pixelsPerSecond))px/с")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button { viewModel.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            TimelineViewWrapper(
                clips: viewModel.timeline.clips,
                playheadPosition: viewModel.playheadPosition,
                pixelsPerSecond: viewModel.pixelsPerSecond,
                waveformData: viewModel.waveformData,
                onSeek: { time in viewModel.seekSmoothly(to: time) },
                onTrimClip: { id, range in viewModel.trimClip(id: id, newSourceRange: range) },
                onTrimEnd: { viewModel.trimEnded() },
                onSelectClip: { id in viewModel.selectedClipId = id },
                silenceZones: viewModel.displayZones,
                onToggleZone: { id in viewModel.toggleReviewZone(id: id) }
            )
        }
    }

    var dropZone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Перетащите видео сюда")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("или нажмите Импорт")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func clipRow(_ clip: TimelineClip) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(clip.isEnabled ? Color.green : Color.red.opacity(0.5))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.isEnabled ? "Включён" : "Выключен")
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(viewModel.selectedClipId == clip.id ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(viewModel.selectedClipId == clip.id ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedClipId = clip.id
        }
    }
}
