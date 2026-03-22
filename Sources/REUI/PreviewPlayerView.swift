import SwiftUI
import AVFoundation
import RECore
import RETimeline

/// AVPlayerLayer wrapped in NSViewRepresentable.
/// Player is RECREATED entirely on each timeline change (not replaceCurrentItem).
public struct PreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.player = player
        return view
    }

    public func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.player = player
    }
}

public class PlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    public var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
