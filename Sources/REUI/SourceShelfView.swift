import SwiftUI
import CoreMedia
import RECore

#if os(macOS)
import AppKit

/// Полка источников над таймлайном: что за ролики в проекте, что с ними и чего не хватает.
public struct SourceShelfView: View {
    @Bindable var viewModel: EditorViewModel

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.timeline.sources) { source in
                    chip(for: source)
                }

                Button {
                    addSources()
                } label: {
                    Label("Добавить видео", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Добавить один или несколько роликов в конец таймлайна")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func chip(for source: MediaSource) -> some View {
        let isOffline = viewModel.offlineSourceIDs.contains(source.id)
        let isSelected = viewModel.selectedSourceId == source.id

        return HStack(spacing: 6) {
            Image(systemName: isOffline ? "exclamationmark.triangle.fill" : "film")
                .font(.caption)
                .foregroundStyle(isOffline ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Text(subtitle(for: source, isOffline: isOffline))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if isOffline {
                Button("Найти…") { relink(source) }
                    .font(.caption2)
                    .buttonStyle(.link)
            } else {
                Button {
                    viewModel.selectedSourceId = source.id
                    viewModel.insertSource(id: source.id, at: viewModel.playheadPosition)
                } label: {
                    Image(systemName: "text.insert")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Вставить на плейхед (клавиша «,» для выбранного ролика)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isOffline ? Color.orange.opacity(0.15)
                      : isSelected ? Color.accentColor.opacity(0.25)
                      : Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1)
        )
        .frame(maxWidth: 260)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.selectedSourceId = source.id }
        .help(source.url.path)
    }

    private func subtitle(for source: MediaSource, isOffline: Bool) -> String {
        if isOffline { return "файл не найден" }

        var parts: [String] = []
        let seconds = CMTimeGetSeconds(source.duration)
        if seconds.isFinite, seconds > 0 {
            parts.append(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
        }
        let size = source.orientedSize
        if size.width > 0, size.height > 0 {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if let lufs = source.integratedLUFS {
            parts.append(String(format: "%.1f LUFS", lufs))
        }
        if !source.hasAudio { parts.append("без звука") }
        return parts.joined(separator: " · ")
    }

    private func addSources() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        viewModel.addSources(urls: panel.urls)
    }

    private func relink(_ source: MediaSource) {
        let panel = NSOpenPanel()
        panel.message = "Где теперь лежит \(source.url.lastPathComponent)?"
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.relinkSource(id: source.id, to: url)
    }
}

#endif
