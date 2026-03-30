import SwiftUI
import AVFoundation
import AVKit

#if os(macOS)
/// AVPlayerLayer wrapped in NSViewRepresentable (macOS).
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

#elseif os(iOS)
/// AVPlayerLayer wrapped in UIViewRepresentable (iOS).
/// Player is RECREATED entirely on each timeline change (not replaceCurrentItem).
public struct PreviewPlayerView: UIViewRepresentable {
    let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    public func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }
}

public class PlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()

    public var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
#endif
