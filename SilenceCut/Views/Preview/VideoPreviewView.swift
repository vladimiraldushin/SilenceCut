import SwiftUI
import AVFoundation
import AppKit

/// Simple video preview using AVPlayerLayer — no system transport controls,
/// no security restrictions from SwiftUI VideoPlayer
struct VideoPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.player = player
    }
}

/// NSView that hosts an AVPlayerLayer
class VideoLayerView: NSView {
    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
