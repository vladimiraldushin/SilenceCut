import SwiftUI
import AVFoundation
import REUI

@main
struct SilenceCutIOSApp: App {
    @State private var viewModel = EditorViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Play audio even when silent switch is on (video editor must always have sound)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            MainEditorView(viewModel: viewModel)
        }
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
    }
}
