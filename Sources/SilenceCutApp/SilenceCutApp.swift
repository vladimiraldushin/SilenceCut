import SwiftUI
import REUI

@main
struct SilenceCutApp: App {
    @State private var viewModel = EditorViewModel()

    var body: some Scene {
        WindowGroup {
            MainEditorView(viewModel: viewModel)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video...") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
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
