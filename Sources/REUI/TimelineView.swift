import SwiftUI
import AppKit
import CoreMedia
import RECore

// MARK: - SwiftUI Wrapper

public struct TimelineViewWrapper: NSViewRepresentable {
    let clips: [TimelineClip]
    let playheadPosition: CMTime
    let pixelsPerSecond: Double
    let onSeek: (CMTime) -> Void
    let onTrimClip: (UUID, CMTimeRange) -> Void
    let onSelectClip: (UUID?) -> Void

    public init(
        clips: [TimelineClip],
        playheadPosition: CMTime,
        pixelsPerSecond: Double,
        onSeek: @escaping (CMTime) -> Void,
        onTrimClip: @escaping (UUID, CMTimeRange) -> Void,
        onSelectClip: @escaping (UUID?) -> Void
    ) {
        self.clips = clips
        self.playheadPosition = playheadPosition
        self.pixelsPerSecond = pixelsPerSecond
        self.onSeek = onSeek
        self.onTrimClip = onTrimClip
        self.onSelectClip = onSelectClip
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)

        let timeline = TimelineNSView()
        timeline.onSeek = onSeek
        timeline.onTrimClip = onTrimClip
        timeline.onSelectClip = onSelectClip
        scrollView.documentView = timeline

        context.coordinator.timelineView = timeline
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let timeline = context.coordinator.timelineView else { return }
        timeline.onSeek = onSeek
        timeline.onTrimClip = onTrimClip
        timeline.onSelectClip = onSelectClip
        timeline.updateTimeline(clips: clips, playheadPosition: playheadPosition, pixelsPerSecond: pixelsPerSecond)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var timelineView: TimelineNSView?
    }
}

// MARK: - Timeline NSView

public class TimelineNSView: NSView {

    // Callbacks
    var onSeek: ((CMTime) -> Void)?
    var onTrimClip: ((UUID, CMTimeRange) -> Void)?
    var onSelectClip: ((UUID?) -> Void)?

    // State
    private var clips: [TimelineClip] = []
    private var pixelsPerSecond: Double = 100
    private var selectedClipId: UUID?

    // Layers
    private let trackLayer = CALayer()
    private let playheadLayer = CALayer()
    private var clipLayers: [UUID: CALayer] = [:]

    // Trim state
    private enum TrimEdge { case left, right }
    private var trimming: (clipId: UUID, edge: TrimEdge, initialRange: CMTimeRange)?

    private let trackHeight: CGFloat = 80
    private let handleWidth: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor

        // Track background
        trackLayer.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        trackLayer.cornerRadius = 4
        layer?.addSublayer(trackLayer)

        // Playhead
        playheadLayer.backgroundColor = NSColor.red.cgColor
        playheadLayer.zPosition = 100
        layer?.addSublayer(playheadLayer)

        // Gestures
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    // MARK: - Update

    func updateTimeline(clips: [TimelineClip], playheadPosition: CMTime, pixelsPerSecond: Double) {
        self.clips = clips
        self.pixelsPerSecond = pixelsPerSecond

        // Calculate total width
        let enabledClips = clips.filter(\.isEnabled)
        let totalDuration = enabledClips.reduce(0.0) { $0 + CMTimeGetSeconds($1.effectiveDuration) }
        let totalWidth = max(totalDuration * pixelsPerSecond, (superview?.bounds.width ?? 800))

        // Resize self to fit content
        let height = trackHeight + 20 // padding
        frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Track background
        trackLayer.frame = CGRect(x: 0, y: 10, width: totalWidth, height: trackHeight)

        // Update clip layers
        var activeIds = Set<UUID>()
        var x: CGFloat = 0

        for clip in clips where clip.isEnabled {
            activeIds.insert(clip.id)
            let width = CGFloat(CMTimeGetSeconds(clip.effectiveDuration) * pixelsPerSecond)

            let clipLayer: CALayer
            if let existing = clipLayers[clip.id] {
                clipLayer = existing
            } else {
                clipLayer = makeClipLayer()
                clipLayers[clip.id] = clipLayer
                trackLayer.addSublayer(clipLayer)
            }

            clipLayer.frame = CGRect(x: x, y: 0, width: max(width, 3), height: trackHeight)
            clipLayer.backgroundColor = (selectedClipId == clip.id)
                ? NSColor.systemBlue.cgColor
                : NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            clipLayer.borderColor = (selectedClipId == clip.id)
                ? NSColor.white.cgColor
                : NSColor.black.withAlphaComponent(0.2).cgColor
            clipLayer.borderWidth = selectedClipId == clip.id ? 2 : 0.5

            // Update label
            if let textLayer = clipLayer.sublayers?.first as? CATextLayer {
                let dur = CMTimeGetSeconds(clip.effectiveDuration)
                textLayer.string = dur < 1 ? String(format: "%.0fms", dur * 1000) : String(format: "%.1fs", dur)
                textLayer.frame = CGRect(x: 4, y: (trackHeight - 16) / 2, width: max(width - 8, 0), height: 16)
                textLayer.isHidden = width < 40
            }

            // Trim handles (visual indicators on edges)
            if let leftHandle = clipLayer.sublayers?[safe: 1] {
                leftHandle.frame = CGRect(x: 0, y: 0, width: 3, height: trackHeight)
                leftHandle.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
            }
            if let rightHandle = clipLayer.sublayers?[safe: 2] {
                rightHandle.frame = CGRect(x: max(width - 3, 0), y: 0, width: 3, height: trackHeight)
                rightHandle.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
            }

            x += width
        }

        // Remove layers for deleted clips
        for (id, layer) in clipLayers where !activeIds.contains(id) {
            layer.removeFromSuperlayer()
            clipLayers.removeValue(forKey: id)
        }

        // Playhead
        let phx = CGFloat(CMTimeGetSeconds(playheadPosition) * pixelsPerSecond)
        playheadLayer.frame = CGRect(x: phx - 1, y: 0, width: 2, height: height)

        // Playhead triangle (at top)
        if playheadLayer.sublayers?.isEmpty ?? true {
            let triangle = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -6, y: height))
            path.addLine(to: CGPoint(x: 7, y: height))
            path.addLine(to: CGPoint(x: 0.5, y: height - 10))
            path.closeSubpath()
            triangle.path = path
            triangle.fillColor = NSColor.red.cgColor
            playheadLayer.addSublayer(triangle)
        }

        CATransaction.commit()
    }

    private func makeClipLayer() -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = 4
        layer.masksToBounds = true

        // Text label
        let textLayer = CATextLayer()
        textLayer.fontSize = 10
        textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(textLayer)

        // Left trim handle
        let leftHandle = CALayer()
        layer.addSublayer(leftHandle)

        // Right trim handle
        let rightHandle = CALayer()
        layer.addSublayer(rightHandle)

        return layer
    }

    // MARK: - Gestures

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10) // offset for track

        // Check if clicking on a clip
        var clickedClip: UUID? = nil
        for (id, layer) in clipLayers {
            if layer.frame.contains(trackPoint) {
                clickedClip = id
                break
            }
        }

        if let id = clickedClip {
            selectedClipId = id
            onSelectClip?(id)
        } else {
            selectedClipId = nil
            onSelectClip?(nil)

            // Seek to clicked position
            let time = CMTime(seconds: Double(point.x) / pixelsPerSecond, preferredTimescale: 600)
            onSeek?(time)
        }

        // Trigger visual update
        updateTimeline(clips: clips, playheadPosition: CMTime(seconds: Double(point.x) / pixelsPerSecond, preferredTimescale: 600), pixelsPerSecond: pixelsPerSecond)
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let point = gesture.location(in: self)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10)

        switch gesture.state {
        case .began:
            // Check if starting on a trim handle
            for clip in clips where clip.isEnabled {
                guard let layer = clipLayers[clip.id] else { continue }
                let frame = layer.frame

                // Left handle hit area (8px)
                if abs(trackPoint.x - frame.minX) < handleWidth {
                    trimming = (clipId: clip.id, edge: .left, initialRange: clip.sourceRange)
                    return
                }
                // Right handle hit area (8px)
                if abs(trackPoint.x - frame.maxX) < handleWidth {
                    trimming = (clipId: clip.id, edge: .right, initialRange: clip.sourceRange)
                    return
                }
            }

            // Not on a handle — scrub/seek
            let time = CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600)
            onSeek?(time)

        case .changed:
            if let trim = trimming {
                // Trimming a clip edge
                let delta = gesture.translation(in: self)
                let timeDelta = CMTime(seconds: Double(delta.x) / pixelsPerSecond, preferredTimescale: 600)

                guard let clipIdx = clips.firstIndex(where: { $0.id == trim.clipId }) else { return }
                let clip = clips[clipIdx]

                var newRange = trim.initialRange
                switch trim.edge {
                case .left:
                    let newStart = CMTimeAdd(trim.initialRange.start, timeDelta)
                    let clampedStart = CMTimeMaximum(clip.availableRange.start, newStart)
                    newRange = CMTimeRange(
                        start: clampedStart,
                        duration: CMTimeSubtract(CMTimeRangeGetEnd(trim.initialRange), clampedStart)
                    )
                case .right:
                    let newDuration = CMTimeAdd(trim.initialRange.duration, timeDelta)
                    let maxDuration = CMTimeSubtract(CMTimeRangeGetEnd(clip.availableRange), newRange.start)
                    newRange = CMTimeRange(
                        start: newRange.start,
                        duration: CMTimeMinimum(CMTimeMaximum(CMTime(seconds: 0.1, preferredTimescale: 600), newDuration), maxDuration)
                    )
                }

                onTrimClip?(trim.clipId, newRange)
            } else {
                // Scrubbing
                let time = CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600)
                onSeek?(time)
            }

        case .ended, .cancelled:
            trimming = nil

        default: break
        }
    }

    // MARK: - Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space
            // Handled by SwiftUI keyboard shortcut
            break
        case 51: // Delete
            if let id = selectedClipId {
                onSelectClip?(nil)
                selectedClipId = nil
                // Delete will be handled by EditorViewModel
            }
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Array Safe Index

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
