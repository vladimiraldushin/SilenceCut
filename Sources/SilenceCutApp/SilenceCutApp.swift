import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RECore
import REUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: EditorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Global key monitor (skip when editing text fields)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let vm = self?.viewModel else { return event }

            // Explicit flag from SwiftUI @FocusState (subtitle text fields)
            if vm.isTextEditingActive { return event }

            // Don't intercept keys when user is typing in a text field
            if let responder = NSApp.keyWindow?.firstResponder {
                let name = String(describing: type(of: responder))
                if responder is NSTextView || responder is NSTextField
                    || name.contains("TextField") || name.contains("TextEditor")
                    || name.contains("FieldEditor") || name.contains("NSText") {
                    return event
                }
                // Check responder chain — if any superview is a text input, pass through
                if let view = responder as? NSView {
                    var current: NSView? = view
                    while let v = current {
                        if v is NSTextField || v is NSTextView {
                            return event
                        }
                        current = v.superview
                    }
                }
            }

            // Клавиши с ⌘/⌃/⌥ — не наши: они уходят в меню. Без этой проверки монитор
            // глотал ⌘O (keyCode 31 — это буква O) и пункт «Открыть видео» не срабатывал.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCommandLike = !modifiers.intersection([.command, .control, .option]).isEmpty
            if hasCommandLike { return event }

            // "?" — hotkey cheatsheet
            if event.characters == "?" {
                vm.showHotkeysHelp.toggle()
                return nil
            }

            let shift = modifiers.contains(.shift)

            switch event.keyCode {
            case 49: // Space — Play/Pause
                vm.togglePlayback()
                return nil
            case 51, 117: // Backspace, Forward Delete
                if vm.selectedClipId != nil {
                    vm.deleteSelectedClip()
                    return nil
                }
            case 38: // J — back 1s
                vm.nudgePlayhead(by: -1.0)
                return nil
            case 40: // K — pause
                if vm.isPlaying { vm.togglePlayback() }
                return nil
            case 37: // L — forward 1s
                vm.nudgePlayhead(by: 1.0)
                return nil
            case 34, 12: // I, Q — ripple trim: cut everything left of playhead
                vm.trimInAtPlayhead()
                return nil
            case 31, 13: // O, W — ripple trim: cut everything right of playhead
                vm.trimOutAtPlayhead()
                return nil
            case 30, 125: // ], ↓ — next cut
                vm.jumpToNextCut()
                return nil
            case 33, 126: // [, ↑ — previous cut
                vm.jumpToPreviousCut()
                return nil
            case 43: // , — вставить выбранный на полке ролик на плейхед
                vm.insertSelectedSourceAtPlayhead()
                return nil
            case 17: // T — выключить/включить клип в выводе
                vm.toggleSelectedClip()
                return nil
            case 6 where shift: // ⇧Z — вписать таймлайн в окно
                vm.zoomToFit()
                return nil
            case 115: // Home — в начало
                vm.jumpToStart()
                return nil
            case 119: // End — в конец
                vm.jumpToEnd()
                return nil
            case 123: // Left arrow — кадр назад, с Shift — секунда
                vm.nudgePlayhead(by: shift ? -1.0 : -1.0 / vm.videoFPS)
                return nil
            case 124: // Right arrow — кадр вперёд, с Shift — секунда
                vm.nudgePlayhead(by: shift ? 1.0 : 1.0 / vm.videoFPS)
                return nil
            default:
                break
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SilenceCutApp: App {
    @State private var viewModel = EditorViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainEditorView(viewModel: viewModel)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    // Ensure app is foreground
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.modelManager.onAppEnteredBackground()
            case .active:
                viewModel.modelManager.onAppEnteredForeground()
            default:
                break
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новый проект") { viewModel.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Открыть проект...") { openProject() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Недавние проекты") {
                    if viewModel.recentProjects.isEmpty {
                        Text("Пусто")
                    } else {
                        ForEach(viewModel.recentProjects) { recent in
                            Button(recent.name) { viewModel.openProjectFile(url: recent.url) }
                                .disabled(!recent.fileExists)
                        }
                        Divider()
                        Button("Очистить список") {
                            RecentProjectsStore.clear()
                            viewModel.refreshRecentProjects()
                        }
                    }
                }

                Divider()
                Button("Импортировать видео...") { openFile() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("Сохранить проект") { viewModel.saveProjectNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!viewModel.hasSources)
                Button("Сохранить проект как...") { saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!viewModel.hasSources)
            }
            CommandMenu("Монтаж") {
                Button("Разрезать на плейхеде") { viewModel.splitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(viewModel.timeline.clips.isEmpty)
                Button("Вставить ролик на плейхед") { viewModel.insertSelectedSourceAtPlayhead() }
                    .disabled(!viewModel.hasSources)
                Button("Удалить выбранный клип") { viewModel.deleteSelectedClip() }
                    .disabled(viewModel.selectedClipId == nil)
                Divider()
                Button("Крупнее") { viewModel.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Мельче") { viewModel.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Вписать в окно") { viewModel.zoomToFit() }
                    .keyboardShortcut("z", modifiers: .shift)
                Divider()
                Button("Экспорт...") { viewModel.exportVideo() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!viewModel.canExport)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Отменить") { viewModel.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!viewModel.canUndo)
                Button("Повторить") { viewModel.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!viewModel.canRedo)
            }
            CommandGroup(after: .help) {
                Button("Горячие клавиши") { viewModel.showHotkeysHelp.toggle() }
                    .keyboardShortcut("/", modifiers: .command)
            }
            // Space/Delete handled in AppDelegate NSEvent monitor
            // (which checks for text field focus before intercepting)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            viewModel.addSources(urls: panel.urls)
        }
    }

    private func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: ProjectStore.fileExtension) ?? .json
        ]
        panel.nameFieldStringValue = viewModel.suggestedProjectFileName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.saveProject(to: url)
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "silencecut") ?? .json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.openProjectFile(url: url)
        }
    }
}
