import SwiftUI
import AVFoundation

@main
struct SilenceCutApp: App {
    @State private var project = EditProject()
    @State private var timelineEngine = TimelineEngine()

    var body: some Scene {
        WindowGroup {
            MainEditorView(project: project, engine: timelineEngine)
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    timelineEngine.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!timelineEngine.canUndo)

                Button("Redo") {
                    timelineEngine.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!timelineEngine.canRedo)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Video...") {
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a video file to edit"

        if panel.runModal() == .OK, let url = panel.url {
            project.sourceURL = url
        }
    }
}
