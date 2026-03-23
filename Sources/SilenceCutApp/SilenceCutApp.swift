import SwiftUI
import AppKit
import REUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: EditorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Global key monitor for Delete/Backspace
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Backspace (keyCode 51) or Forward Delete (keyCode 117)
            if event.keyCode == 51 || event.keyCode == 117 {
                if let vm = self?.viewModel, vm.selectedClipId != nil {
                    vm.deleteSelectedClip()
                    return nil // consume event
                }
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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video...") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { viewModel.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!viewModel.canUndo)
                Button("Redo") { viewModel.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!viewModel.canRedo)
            }
            CommandGroup(after: .toolbar) {
                Button("Play / Pause") { viewModel.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Delete Selected Clip") { viewModel.deleteSelectedClip() }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("Delete Selected (Backspace)") { viewModel.deleteSelectedClip() }
                    .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: [])
            }
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
}
