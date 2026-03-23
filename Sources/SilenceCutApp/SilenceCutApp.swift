import SwiftUI
import AppKit
import REUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: EditorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Global key monitor (skip when editing text fields)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let vm = self?.viewModel else { return event }

            // Don't intercept keys when user is typing in a text field
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            switch event.keyCode {
            case 51, 117: // Backspace, Forward Delete
                if vm.selectedClipId != nil {
                    vm.deleteSelectedClip()
                    return nil
                }
            case 38: // J — reverse/slow
                vm.nudgePlayhead(by: -1.0)
                return nil
            case 40: // K — pause
                if vm.isPlaying { vm.togglePlayback() }
                return nil
            case 37: // L — forward/fast
                vm.nudgePlayhead(by: 1.0)
                return nil
            case 34: // I — set in point (split + delete left)
                vm.splitAtPlayhead()
                return nil
            case 31: // O — set out point (split + delete right)
                vm.splitAtPlayhead()
                return nil
            case 123: // Left arrow — step back 1 frame
                vm.nudgePlayhead(by: -1.0/30.0)
                return nil
            case 124: // Right arrow — step forward 1 frame
                vm.nudgePlayhead(by: 1.0/30.0)
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
