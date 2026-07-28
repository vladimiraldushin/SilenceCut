import SwiftUI
import AppKit
import UniformTypeIdentifiers
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

            // "?" — hotkey cheatsheet
            if event.characters == "?" {
                vm.showHotkeysHelp.toggle()
                return nil
            }

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
            case 34: // I — trim in: cut everything left of playhead in current clip
                vm.trimInAtPlayhead()
                return nil
            case 31: // O — trim out: cut everything right of playhead in current clip
                vm.trimOutAtPlayhead()
                return nil
            case 30: // ] — next cut
                vm.jumpToNextCut()
                return nil
            case 33: // [ — previous cut
                vm.jumpToPreviousCut()
                return nil
            case 123: // Left arrow — step back 1 frame (real fps)
                vm.nudgePlayhead(by: -1.0 / vm.videoFPS)
                return nil
            case 124: // Right arrow — step forward 1 frame (real fps)
                vm.nudgePlayhead(by: 1.0 / vm.videoFPS)
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
                Button("Открыть видео...") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Открыть проект...") { openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Сохранить проект") { viewModel.saveProjectNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(viewModel.project.sourceURL == nil)
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
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importVideo(url: url)
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
