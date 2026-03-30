import SwiftUI
import CoreMedia
import RECore
import REAudioAnalysis

#if os(macOS)
import AppKit

// MARK: - macOS SwiftUI Wrapper

public struct TimelineViewWrapper: NSViewRepresentable {
    let clips: [TimelineClip]
    let playheadPosition: CMTime
    let pixelsPerSecond: Double
    let waveformData: WaveformData?
    let onSeek: (CMTime) -> Void
    let onTrimClip: (UUID, CMTimeRange) -> Void
    let onTrimEnd: () -> Void
    let onSelectClip: (UUID?) -> Void

    public init(
        clips: [TimelineClip],
        playheadPosition: CMTime,
        pixelsPerSecond: Double,
        waveformData: WaveformData? = nil,
        onSeek: @escaping (CMTime) -> Void,
        onTrimClip: @escaping (UUID, CMTimeRange) -> Void,
        onTrimEnd: @escaping () -> Void = {},
        onSelectClip: @escaping (UUID?) -> Void
    ) {
        self.clips = clips
        self.playheadPosition = playheadPosition
        self.pixelsPerSecond = pixelsPerSecond
        self.waveformData = waveformData
        self.onSeek = onSeek
        self.onTrimClip = onTrimClip
        self.onTrimEnd = onTrimEnd
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
        timeline.onTrimEnd = onTrimEnd
        timeline.onSelectClip = onSelectClip
        scrollView.documentView = timeline

        context.coordinator.timelineView = timeline
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let timeline = context.coordinator.timelineView else { return }
        timeline.onSeek = onSeek
        timeline.onTrimClip = onTrimClip
        timeline.onTrimEnd = onTrimEnd
        timeline.onSelectClip = onSelectClip
        timeline.updateTimeline(clips: clips, playheadPosition: playheadPosition, pixelsPerSecond: pixelsPerSecond, waveformData: waveformData)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var timelineView: TimelineNSView?
    }
}

// MARK: - Timeline NSView (macOS)

public class TimelineNSView: NSView {

    // Callbacks
    var onSeek: ((CMTime) -> Void)?
    var onTrimClip: ((UUID, CMTimeRange) -> Void)?
    var onTrimEnd: (() -> Void)?
    var onSelectClip: ((UUID?) -> Void)?

    // State
    private var clips: [TimelineClip] = []
    private var pixelsPerSecond: Double = 100
    private var selectedClipId: UUID?
    private var waveformData: WaveformData?

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

        trackLayer.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        trackLayer.cornerRadius = 4
        layer?.addSublayer(trackLayer)

        playheadLayer.backgroundColor = NSColor.red.cgColor
        playheadLayer.zPosition = 100
        layer?.addSublayer(playheadLayer)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    // MARK: - Update

    func updateTimeline(clips: [TimelineClip], playheadPosition: CMTime, pixelsPerSecond: Double, waveformData: WaveformData? = nil) {
        self.clips = clips
        self.pixelsPerSecond = pixelsPerSecond
        if let wd = waveformData { self.waveformData = wd }

        let enabledClips = clips.filter(\.isEnabled)
        let totalDuration = enabledClips.reduce(0.0) { $0 + CMTimeGetSeconds($1.effectiveDuration) }
        let totalWidth = max(totalDuration * pixelsPerSecond, (superview?.bounds.width ?? 800))

        let height = trackHeight + 20
        frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        trackLayer.frame = CGRect(x: 0, y: 10, width: totalWidth, height: trackHeight)

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

            if let textLayer = clipLayer.sublayers?.first as? CATextLayer {
                let dur = CMTimeGetSeconds(clip.effectiveDuration)
                textLayer.string = dur < 1 ? String(format: "%.0fms", dur * 1000) : String(format: "%.1fs", dur)
                textLayer.frame = CGRect(x: 4, y: (trackHeight - 16) / 2, width: max(width - 8, 0), height: 16)
                textLayer.isHidden = width < 40
            }

            let isSelected = selectedClipId == clip.id
            let handleColor = isSelected
                ? NSColor.systemYellow.cgColor
                : NSColor.white.withAlphaComponent(0.5).cgColor
            let handleW: CGFloat = isSelected ? 5 : 3

            if let leftHandle = clipLayer.sublayers?[safe: 1] {
                leftHandle.frame = CGRect(x: 0, y: 0, width: handleW, height: trackHeight)
                leftHandle.backgroundColor = handleColor
                leftHandle.cornerRadius = 1.5
            }
            if let rightHandle = clipLayer.sublayers?[safe: 2] {
                rightHandle.frame = CGRect(x: max(width - handleW, 0), y: 0, width: handleW, height: trackHeight)
                rightHandle.backgroundColor = handleColor
                rightHandle.cornerRadius = 1.5
            }

            if let waveform = waveformData {
                let waveLayer: CAShapeLayer
                if let existing = clipLayer.sublayers?[safe: 3] as? CAShapeLayer {
                    waveLayer = existing
                } else {
                    waveLayer = CAShapeLayer()
                    waveLayer.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
                    waveLayer.lineWidth = 1
                    waveLayer.fillColor = nil
                    clipLayer.addSublayer(waveLayer)
                }
                waveLayer.frame = CGRect(x: 0, y: 0, width: width, height: trackHeight)

                let path = CGMutablePath()
                let midY = trackHeight / 2
                let amp = trackHeight / 2 * 0.85
                let startSample = Int(CMTimeGetSeconds(clip.sourceRange.start) * Double(waveform.samplesPerSecond))
                let endSample = Int(CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange)) * Double(waveform.samplesPerSecond))
                let sampleCount = max(1, endSample - startSample)

                for si in startSample..<min(endSample, waveform.peaks.count) {
                    let progress = CGFloat(si - startSample) / CGFloat(sampleCount)
                    let px = progress * width
                    let h = CGFloat(waveform.peaks[si]) * amp
                    path.move(to: CGPoint(x: px, y: midY - h))
                    path.addLine(to: CGPoint(x: px, y: midY + h))
                }
                waveLayer.path = path
            }

            x += width
        }

        for (id, layer) in clipLayers where !activeIds.contains(id) {
            layer.removeFromSuperlayer()
            clipLayers.removeValue(forKey: id)
        }

        let phx = CGFloat(CMTimeGetSeconds(playheadPosition) * pixelsPerSecond)
        playheadLayer.frame = CGRect(x: phx - 1, y: 0, width: 2, height: height)

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

        let textLayer = CATextLayer()
        textLayer.fontSize = 10
        textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(textLayer)

        let leftHandle = CALayer()
        layer.addSublayer(leftHandle)

        let rightHandle = CALayer()
        layer.addSublayer(rightHandle)

        return layer
    }

    // MARK: - Gestures

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10)

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
            let time = CMTime(seconds: Double(point.x) / pixelsPerSecond, preferredTimescale: 600)
            onSeek?(time)
        }

        updateTimeline(clips: clips, playheadPosition: CMTime(seconds: Double(point.x) / pixelsPerSecond, preferredTimescale: 600), pixelsPerSecond: pixelsPerSecond)
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let point = gesture.location(in: self)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10)

        switch gesture.state {
        case .began:
            let sortedClips: [TimelineClip] = {
                var sorted = clips.filter { $0.isEnabled }
                if let selId = selectedClipId,
                   let idx = sorted.firstIndex(where: { $0.id == selId }) {
                    let selected = sorted.remove(at: idx)
                    sorted.insert(selected, at: 0)
                }
                return sorted
            }()

            for clip in sortedClips {
                guard let layer = clipLayers[clip.id] else { continue }
                let frame = layer.frame

                if abs(trackPoint.x - frame.minX) < handleWidth {
                    trimming = (clipId: clip.id, edge: .left, initialRange: clip.sourceRange)
                    selectedClipId = clip.id
                    onSelectClip?(clip.id)
                    return
                }
                if abs(trackPoint.x - frame.maxX) < handleWidth {
                    trimming = (clipId: clip.id, edge: .right, initialRange: clip.sourceRange)
                    selectedClipId = clip.id
                    onSelectClip?(clip.id)
                    return
                }
            }

            let time = CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600)
            onSeek?(time)

        case .changed:
            if let trim = trimming {
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
                let time = CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600)
                onSeek?(time)
            }

        case .ended, .cancelled:
            if trimming != nil {
                onTrimEnd?()
            }
            trimming = nil

        default: break
        }
    }

    // MARK: - Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: break // Space — handled by SwiftUI
        case 51:
            if let id = selectedClipId {
                onSelectClip?(nil)
                selectedClipId = nil
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Cursor

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10)

        var onHandle = false
        for clip in clips where clip.isEnabled {
            guard let layer = clipLayers[clip.id] else { continue }
            let frame = layer.frame
            if abs(trackPoint.x - frame.minX) < handleWidth || abs(trackPoint.x - frame.maxX) < handleWidth {
                if frame.minY <= trackPoint.y && trackPoint.y <= frame.maxY {
                    onHandle = true
                    break
                }
            }
        }
        NSCursor.current.set()
        if onHandle {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow], owner: self))
    }
}

#elseif os(iOS)
import UIKit

// MARK: - iOS SwiftUI Wrapper

public struct TimelineViewWrapper: UIViewRepresentable {
    let clips: [TimelineClip]
    let playheadPosition: CMTime
    let pixelsPerSecond: Double
    let waveformData: WaveformData?
    let onSeek: (CMTime) -> Void
    let onTrimClip: (UUID, CMTimeRange) -> Void
    let onTrimEnd: () -> Void
    let onSelectClip: (UUID?) -> Void

    public init(
        clips: [TimelineClip],
        playheadPosition: CMTime,
        pixelsPerSecond: Double,
        waveformData: WaveformData? = nil,
        onSeek: @escaping (CMTime) -> Void,
        onTrimClip: @escaping (UUID, CMTimeRange) -> Void,
        onTrimEnd: @escaping () -> Void = {},
        onSelectClip: @escaping (UUID?) -> Void
    ) {
        self.clips = clips
        self.playheadPosition = playheadPosition
        self.pixelsPerSecond = pixelsPerSecond
        self.waveformData = waveformData
        self.onSeek = onSeek
        self.onTrimClip = onTrimClip
        self.onTrimEnd = onTrimEnd
        self.onSelectClip = onSelectClip
    }

    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.delaysContentTouches = true
        scrollView.canCancelContentTouches = true
        scrollView.backgroundColor = UIColor(white: 0.1, alpha: 1)

        let timeline = TimelineUIView()
        timeline.onSeek = onSeek
        timeline.onTrimClip = onTrimClip
        timeline.onTrimEnd = onTrimEnd
        timeline.onSelectClip = onSelectClip
        scrollView.addSubview(timeline)

        // Tap doesn't conflict with scroll — UIScrollView handles pan, tap fires independently
        // ScrollView pan should fail if scrub or trim pan starts (they have priority near playhead/handles)
        scrollView.panGestureRecognizer.require(toFail: timeline.scrubPanGesture)
        scrollView.panGestureRecognizer.require(toFail: timeline.trimPanGesture)

        context.coordinator.timelineView = timeline
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    public func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let timeline = context.coordinator.timelineView else { return }
        timeline.onSeek = onSeek
        timeline.onTrimClip = onTrimClip
        timeline.onTrimEnd = onTrimEnd
        timeline.onSelectClip = onSelectClip
        timeline.updateTimeline(
            clips: clips,
            playheadPosition: playheadPosition,
            pixelsPerSecond: pixelsPerSecond,
            waveformData: waveformData,
            scrollViewWidth: scrollView.bounds.width
        )
        // Only set horizontal content size — lock vertical to scrollView height to prevent vertical bounce
        scrollView.contentSize = CGSize(width: timeline.frame.width, height: scrollView.bounds.height)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var timelineView: TimelineUIView?
        var scrollView: UIScrollView?
    }
}

// MARK: - Timeline UIView (iOS)

public class TimelineUIView: UIView, UIGestureRecognizerDelegate {

    var onSeek: ((CMTime) -> Void)?
    var onTrimClip: ((UUID, CMTimeRange) -> Void)?
    var onTrimEnd: (() -> Void)?
    var onSelectClip: ((UUID?) -> Void)?

    private var clips: [TimelineClip] = []
    private var pixelsPerSecond: Double = 100
    private var selectedClipId: UUID?
    private var waveformData: WaveformData?

    private let trackLayer = CALayer()
    private let playheadLayer = CALayer()
    private var clipLayers: [UUID: CALayer] = [:]

    private enum TrimEdge { case left, right }
    private var trimming: (clipId: UUID, edge: TrimEdge, initialRange: CMTimeRange)?

    private let trackHeight: CGFloat = 80
    private let handleWidth: CGFloat = 22  // 44pt touch target / 2 = 22pt from edge

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    var trimPanGesture: UIPanGestureRecognizer!
    var scrubPanGesture: UIPanGestureRecognizer!
    private var currentPlayheadX: CGFloat = 0  // updated in updateTimeline
    private let playheadHitWidth: CGFloat = 30  // touch target for playhead drag

    private func setup() {
        backgroundColor = UIColor(white: 0.1, alpha: 1)

        trackLayer.backgroundColor = UIColor(white: 0.15, alpha: 1).cgColor
        trackLayer.cornerRadius = 4
        layer.addSublayer(trackLayer)

        playheadLayer.backgroundColor = UIColor.systemRed.cgColor
        playheadLayer.zPosition = 100
        layer.addSublayer(playheadLayer)

        // Tap = seek to position or select clip
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // Pan on trim handles only
        trimPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        trimPanGesture.delegate = self
        addGestureRecognizer(trimPanGesture)

        // Pan on playhead = scrub
        scrubPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrubPan(_:)))
        scrubPanGesture.delegate = self
        addGestureRecognizer(scrubPanGesture)
    }

    // MARK: - Gesture Delegate

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only filter our own gestures — let UIScrollView's pan and everything else through
        let point = gestureRecognizer.location(in: self)

        if gestureRecognizer === trimPanGesture {
            let trackPoint = CGPoint(x: point.x, y: point.y - 10)
            for clip in clips where clip.isEnabled {
                guard let layer = clipLayers[clip.id] else { continue }
                let frame = layer.frame
                if abs(trackPoint.x - frame.minX) < handleWidth || abs(trackPoint.x - frame.maxX) < handleWidth {
                    if frame.minY <= trackPoint.y && trackPoint.y <= frame.maxY {
                        return true
                    }
                }
            }
            return false
        }

        if gestureRecognizer === scrubPanGesture {
            // Activate only if touch is near the playhead line
            return abs(point.x - currentPlayheadX) < playheadHitWidth
        }

        return true  // Let all other gestures (UIScrollView pan, tap) through
    }

    @objc private func handleScrubPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        let time = CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600)
        onSeek?(time)
    }

    func updateTimeline(clips: [TimelineClip], playheadPosition: CMTime, pixelsPerSecond: Double, waveformData: WaveformData? = nil, scrollViewWidth: CGFloat = 400) {
        self.clips = clips
        self.pixelsPerSecond = pixelsPerSecond
        if let wd = waveformData { self.waveformData = wd }

        let enabledClips = clips.filter(\.isEnabled)
        let totalDuration = enabledClips.reduce(0.0) { $0 + CMTimeGetSeconds($1.effectiveDuration) }
        let totalWidth = max(totalDuration * pixelsPerSecond, Double(scrollViewWidth))

        let height = trackHeight + 20
        frame = CGRect(x: 0, y: 0, width: totalWidth, height: height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        trackLayer.frame = CGRect(x: 0, y: 10, width: totalWidth, height: trackHeight)

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
                ? UIColor.systemBlue.cgColor
                : UIColor.systemGreen.withAlphaComponent(0.6).cgColor
            clipLayer.borderColor = (selectedClipId == clip.id)
                ? UIColor.white.cgColor
                : UIColor.black.withAlphaComponent(0.2).cgColor
            clipLayer.borderWidth = selectedClipId == clip.id ? 2 : 0.5

            if let textLayer = clipLayer.sublayers?.first as? CATextLayer {
                let dur = CMTimeGetSeconds(clip.effectiveDuration)
                textLayer.string = dur < 1 ? String(format: "%.0fms", dur * 1000) : String(format: "%.1fs", dur)
                textLayer.frame = CGRect(x: 4, y: (trackHeight - 16) / 2, width: max(width - 8, 0), height: 16)
                textLayer.isHidden = width < 40
            }

            let isSelected = selectedClipId == clip.id
            let handleColor = isSelected
                ? UIColor.systemYellow.cgColor
                : UIColor.white.withAlphaComponent(0.5).cgColor
            let handleW: CGFloat = isSelected ? 6 : 4

            if clipLayer.sublayers?.count ?? 0 > 1, let leftHandle = clipLayer.sublayers?[1] {
                leftHandle.frame = CGRect(x: 0, y: 0, width: handleW, height: trackHeight)
                leftHandle.backgroundColor = handleColor
                leftHandle.cornerRadius = 2
            }
            if clipLayer.sublayers?.count ?? 0 > 2, let rightHandle = clipLayer.sublayers?[2] {
                rightHandle.frame = CGRect(x: max(width - handleW, 0), y: 0, width: handleW, height: trackHeight)
                rightHandle.backgroundColor = handleColor
                rightHandle.cornerRadius = 2
            }

            if let waveform = waveformData {
                let waveLayer: CAShapeLayer
                if clipLayer.sublayers?.count ?? 0 > 3, let existing = clipLayer.sublayers?[3] as? CAShapeLayer {
                    waveLayer = existing
                } else {
                    waveLayer = CAShapeLayer()
                    waveLayer.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
                    waveLayer.lineWidth = 1
                    waveLayer.fillColor = nil
                    clipLayer.addSublayer(waveLayer)
                }
                waveLayer.frame = CGRect(x: 0, y: 0, width: width, height: trackHeight)

                let path = CGMutablePath()
                let midY = trackHeight / 2
                let amp = trackHeight / 2 * 0.85
                let startSample = Int(CMTimeGetSeconds(clip.sourceRange.start) * Double(waveform.samplesPerSecond))
                let endSample = Int(CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange)) * Double(waveform.samplesPerSecond))
                let sampleCount = max(1, endSample - startSample)

                for si in startSample..<min(endSample, waveform.peaks.count) {
                    let progress = CGFloat(si - startSample) / CGFloat(sampleCount)
                    let px = progress * width
                    let h = CGFloat(waveform.peaks[si]) * amp
                    path.move(to: CGPoint(x: px, y: midY - h))
                    path.addLine(to: CGPoint(x: px, y: midY + h))
                }
                waveLayer.path = path
            }

            x += width
        }

        for (id, layer) in clipLayers where !activeIds.contains(id) {
            layer.removeFromSuperlayer()
            clipLayers.removeValue(forKey: id)
        }

        let phx = CGFloat(CMTimeGetSeconds(playheadPosition) * pixelsPerSecond)
        currentPlayheadX = phx  // for scrub hit testing
        playheadLayer.frame = CGRect(x: phx - 1, y: 0, width: 2, height: height)

        if playheadLayer.sublayers?.isEmpty ?? true {
            let triangle = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -6, y: 0))
            path.addLine(to: CGPoint(x: 7, y: 0))
            path.addLine(to: CGPoint(x: 0.5, y: 10))
            path.closeSubpath()
            triangle.path = path
            triangle.fillColor = UIColor.systemRed.cgColor
            playheadLayer.addSublayer(triangle)
        }

        CATransaction.commit()
    }

    private func makeClipLayer() -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = 4
        layer.masksToBounds = true

        let textLayer = CATextLayer()
        textLayer.fontSize = 10
        textLayer.foregroundColor = UIColor.white.withAlphaComponent(0.7).cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(textLayer)

        let leftHandle = CALayer()
        layer.addSublayer(leftHandle)

        let rightHandle = CALayer()
        layer.addSublayer(rightHandle)

        return layer
    }

    // MARK: - Touch Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10)

        // Always seek to tap position (move playhead)
        let time = CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600)
        onSeek?(time)

        // Also select/deselect clip if tapped on one
        var tappedClip: UUID? = nil
        for (id, layer) in clipLayers {
            if layer.frame.contains(trackPoint) {
                tappedClip = id
                break
            }
        }

        if let id = tappedClip {
            selectedClipId = id
            onSelectClip?(id)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            selectedClipId = nil
            onSelectClip?(nil)
        }

        updateTimeline(clips: clips, playheadPosition: CMTime(seconds: max(0, Double(point.x) / pixelsPerSecond), preferredTimescale: 600), pixelsPerSecond: pixelsPerSecond)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        let trackPoint = CGPoint(x: point.x, y: point.y - 10)

        switch gesture.state {
        case .began:
            let sortedClips: [TimelineClip] = {
                var sorted = clips.filter { $0.isEnabled }
                if let selId = selectedClipId,
                   let idx = sorted.firstIndex(where: { $0.id == selId }) {
                    let selected = sorted.remove(at: idx)
                    sorted.insert(selected, at: 0)
                }
                return sorted
            }()

            // gestureRecognizerShouldBegin already verified we're on a handle
            for clip in sortedClips {
                guard let layer = clipLayers[clip.id] else { continue }
                let frame = layer.frame

                if abs(trackPoint.x - frame.minX) < handleWidth {
                    trimming = (clipId: clip.id, edge: .left, initialRange: clip.sourceRange)
                    selectedClipId = clip.id
                    onSelectClip?(clip.id)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    return
                }
                if abs(trackPoint.x - frame.maxX) < handleWidth {
                    trimming = (clipId: clip.id, edge: .right, initialRange: clip.sourceRange)
                    selectedClipId = clip.id
                    onSelectClip?(clip.id)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    return
                }
            }

        case .changed:
            if let trim = trimming {
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
            }

        case .ended, .cancelled:
            if trimming != nil {
                onTrimEnd?()
            }
            trimming = nil

        default: break
        }
    }
}
#endif

// MARK: - Array Safe Index

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
