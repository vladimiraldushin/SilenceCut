#if os(macOS)
import SwiftUI
import AppKit
import RECore

/// Стартовый экран: список проектов вместо пустого окна.
/// Показывается, пока проект не открыт, и уступает место редактору сразу после этого.
public struct ProjectBrowserView: View {
    @Bindable var viewModel: EditorViewModel
    let onOpenProject: () -> Void
    let onImportVideo: () -> Void

    public init(
        viewModel: EditorViewModel,
        onOpenProject: @escaping () -> Void,
        onImportVideo: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenProject = onOpenProject
        self.onImportVideo = onImportVideo
    }

    public var body: some View {
        HStack(spacing: 0) {
            actions
            Divider()
            recentList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.refreshRecentProjects() }
    }

    // MARK: - Левая колонка

    private var actions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SilenceCut")
                    .font(.largeTitle.weight(.semibold))
                Text("Монтаж без пауз")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            Button(action: onImportVideo) {
                Label("Новый проект", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Button(action: onOpenProject) {
                Label("Открыть проект…", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            Text("Новый проект начинается с выбора видео — сразу после этого приложение\nспросит, куда сохранить сам проект, и дальше будет писать туда само.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(28)
        .frame(width: 320)
    }

    // MARK: - Список проектов

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Недавние проекты")
                    .font(.headline)
                Spacer()
                if !viewModel.recentProjects.isEmpty {
                    Button("Очистить список") {
                        RecentProjectsStore.clear()
                        viewModel.refreshRecentProjects()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if viewModel.recentProjects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.recentProjects) { project in
                            row(for: project)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Проектов пока нет")
                .foregroundStyle(.secondary)
            Text("Начните новый — он появится в этом списке")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for project: RecentProject) -> some View {
        let missing = !project.fileExists

        return Button {
            guard !missing else { return }
            viewModel.openProjectFile(url: project.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: missing ? "questionmark.folder" : "film")
                    .font(.title3)
                    .foregroundStyle(missing ? .orange : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .fontWeight(.medium)
                        .foregroundStyle(missing ? .secondary : .primary)
                    Text(subtitle(for: project, missing: missing))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.url.path)
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
            .disabled(missing)
            Button("Убрать из списка") {
                viewModel.removeFromRecentProjects(url: project.url)
            }
        }
    }

    private func subtitle(for project: RecentProject, missing: Bool) -> String {
        if missing { return "Файл не найден — \(project.url.path)" }
        var parts: [String] = []
        if project.durationSeconds > 0 {
            let total = Int(project.durationSeconds.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if project.clipCount > 0 { parts.append("клипов: \(project.clipCount)") }
        if project.sourceCount > 1 { parts.append("роликов: \(project.sourceCount)") }
        parts.append(project.url.deletingLastPathComponent().path)
        return parts.joined(separator: " · ")
    }
}
#endif
