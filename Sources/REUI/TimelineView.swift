import SwiftUI
import CoreMedia
import RECore
import REAudioAnalysis

// MARK: - Silence Zone (pause review overlay)

public struct TimelineSilenceZone: Identifiable, Equatable {
    public let id: UUID
    public let startSeconds: Double   // таймлайн-время, сек
    public let endSeconds: Double
    public let willCut: Bool          // true = будет вырезана

    public init(id: UUID, startSeconds: Double, endSeconds: Double, willCut: Bool) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.willCut = willCut
    }
}

#if os(macOS)
import AppKit

// MARK: - macOS SwiftUI Wrapper

public struct TimelineViewWrapper: NSViewRepresentable {
    let clips: [TimelineClip]
    let overlays: [OverlayClip]
    let playheadPosition: CMTime
    let pixelsPerSecond: Double
    let waveforms: [UUID: WaveformData]
    let sourceNames: [UUID: String]
    let selectedClipId: UUID?
    let selectedOverlayId: UUID?
    let onSeek: (CMTime) -> Void
    let onTrimClip: (UUID, CMTimeRange) -> Void
    let onTrimEnd: () -> Void
    let onSelectClip: (UUID?) -> Void
    let silenceZones: [TimelineSilenceZone]
    let onToggleZone: ((UUID) -> Void)?
    let onSelectOverlay: ((UUID?) -> Void)?
    let onDropFile: ((URL, CMTime, Bool) -> Void)?
    let onMoveOverlay: ((UUID, CMTime) -> Void)?
    let onTrimOverlay: ((UUID, CMTimeRange, CMTime) -> Void)?
    let onOverlayDragEnd: (() -> Void)?

    public init(
        clips: [TimelineClip],
        overlays: [OverlayClip] = [],
        playheadPosition: CMTime,
        pixelsPerSecond: Double,
        waveforms: [UUID: WaveformData] = [:],
        sourceNames: [UUID: String] = [:],
        selectedClipId: UUID? = nil,
        selectedOverlayId: UUID? = nil,
        onSeek: @escaping (CMTime) -> Void,
        onTrimClip: @escaping (UUID, CMTimeRange) -> Void,
        onTrimEnd: @escaping () -> Void = {},
        onSelectClip: @escaping (UUID?) -> Void,
        silenceZones: [TimelineSilenceZone] = [],
        onToggleZone: ((UUID) -> Void)? = nil,
        onSelectOverlay: ((UUID?) -> Void)? = nil,
        onDropFile: ((URL, CMTime, Bool) -> Void)? = nil,
        onMoveOverlay: ((UUID, CMTime) -> Void)? = nil,
        onTrimOverlay: ((UUID, CMTimeRange, CMTime) -> Void)? = nil,
        onOverlayDragEnd: (() -> Void)? = nil
    ) {
        self.clips = clips
        self.overlays = overlays
        self.playheadPosition = playheadPosition
        self.pixelsPerSecond = pixelsPerSecond
        self.waveforms = waveforms
        self.sourceNames = sourceNames
        self.selectedClipId = selectedClipId
        self.selectedOverlayId = selectedOverlayId
        self.onSeek = onSeek
        self.onTrimClip = onTrimClip
        self.onTrimEnd = onTrimEnd
        self.onSelectClip = onSelectClip
        self.silenceZones = silenceZones
        self.onToggleZone = onToggleZone
        self.onSelectOverlay = onSelectOverlay
        self.onDropFile = onDropFile
        self.onMoveOverlay = onMoveOverlay
        self.onTrimOverlay = onTrimOverlay
        self.onOverlayDragEnd = onOverlayDragEnd
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)

        let timeline = TimelineNSView()
        wire(timeline)
        scrollView.documentView = timeline

        context.coordinator.timelineView = timeline
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let timeline = context.coordinator.timelineView else { return }
        wire(timeline)
        timeline.updateTimeline(
            clips: clips,
            overlays: overlays,
            playheadPosition: playheadPosition,
            pixelsPerSecond: pixelsPerSecond,
            waveforms: waveforms,
            sourceNames: sourceNames,
            selectedClipId: selectedClipId,
            selectedOverlayId: selectedOverlayId,
            silenceZones: silenceZones
        )
    }

    private func wire(_ timeline: TimelineNSView) {
        timeline.onSeek = onSeek
        timeline.onTrimClip = onTrimClip
        timeline.onTrimEnd = onTrimEnd
        timeline.onSelectClip = onSelectClip
        timeline.onToggleZone = onToggleZone
        timeline.onSelectOverlay = onSelectOverlay
        timeline.onDropFile = onDropFile
        timeline.onMoveOverlay = onMoveOverlay
        timeline.onTrimOverlay = onTrimOverlay
        timeline.onOverlayDragEnd = onOverlayDragEnd
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var timelineView: TimelineNSView?
    }
}

// MARK: - Timeline NSView (macOS)

/// Две дорожки: нижняя — хребет со звуком и волной, верхняя — перебивки.
/// Файл из Finder можно кинуть на любую: на верхнюю ляжет перебивкой, на нижнюю — в конец хребта.
public class TimelineNSView: NSView {

    // Callbacks
    var onSeek: ((CMTime) -> Void)?
    var onTrimClip: ((UUID, CMTimeRange) -> Void)?
    var onTrimEnd: (() -> Void)?
    var onSelectClip: ((UUID?) -> Void)?
    var onToggleZone: ((UUID) -> Void)?
    var onSelectOverlay: ((UUID?) -> Void)?
    /// (url, время таймлайна, дорожка перебивок?)
    var onDropFile: ((URL, CMTime, Bool) -> Void)?
    var onMoveOverlay: ((UUID, CMTime) -> Void)?
    /// (id, новый диапазон исходника, новое начало на таймлайне)
    var onTrimOverlay: ((UUID, CMTimeRange, CMTime) -> Void)?
    var onOverlayDragEnd: (() -> Void)?

    // State
    private var clips: [TimelineClip] = []
    private var overlays: [OverlayClip] = []
    private var pixelsPerSecond: Double = 100
    private var selectedClipId: UUID?
    private var selectedOverlayId: UUID?
    private var waveforms: [UUID: WaveformData] = [:]
    private var sourceNames: [UUID: String] = [:]
    private var silenceZones: [TimelineSilenceZone] = []
    private var playheadSeconds: Double = 0

    // Layers
    private let spineLayer = CALayer()
    private let overlayLaneLayer = CALayer()
    private let playheadLayer = CALayer()
    private var clipLayers: [UUID: CALayer] = [:]
    private var overlayLayers: [UUID: CALayer] = [:]
    private var zoneLayers: [UUID: CAShapeLayer] = [:]

    // Drag state
    private enum TrimEdge { case left, right }
    private var trimming: (clipId: UUID, edge: TrimEdge, initialRange: CMTimeRange)?

    private enum OverlayDragMode { case move, left, right }
    private var overlayDrag: (
        id: UUID, mode: OverlayDragMode,
        initialSourceRange: CMTimeRange, initialStart: Double
    )?

    // Geometry
    private let spineHeight: CGFloat = 80
    private let overlayHeight: CGFloat = 40
    private let laneGap: CGFloat = 6
    private let bottomInset: CGFloat = 10
    private let handleWidth: CGFloat = 8

    private var spineY: CGFloat { bottomInset }
    private var overlayY: CGFloat { spineY + spineHeight + laneGap }
    private var totalHeight: CGFloat { overlayY + overlayHeight + bottomInset }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor

        overlayLaneLayer.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        overlayLaneLayer.cornerRadius = 4
        overlayLaneLayer.borderWidth = 0
        layer?.addSublayer(overlayLaneLayer)

        spineLayer.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        spineLayer.cornerRadius = 4
        layer?.addSublayer(spineLayer)

        playheadLayer.backgroundColor = NSColor.red.cgColor
        playheadLayer.zPosition = 100
        layer?.addSublayer(playheadLayer)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Update

    func updateTimeline(
        clips: [TimelineClip],
        overlays: [OverlayClip] = [],
        playheadPosition: CMTime,
        pixelsPerSecond: Double,
        waveforms: [UUID: WaveformData]? = nil,
        sourceNames: [UUID: String]? = nil,
        selectedClipId: UUID?? = nil,
        selectedOverlayId: UUID?? = nil,
        silenceZones: [TimelineSilenceZone]? = nil
    ) {
        self.clips = clips
        self.overlays = overlays
        self.pixelsPerSecond = pixelsPerSecond
        self.playheadSeconds = CMTimeGetSeconds(playheadPosition)
        if let waveforms { self.waveforms = waveforms }
        if let sourceNames { self.sourceNames = sourceNames }
        if let selectedClipId { self.selectedClipId = selectedClipId }
        if let selectedOverlayId { self.selectedOverlayId = selectedOverlayId }
        if let silenceZones { self.silenceZones = silenceZones }

        let enabledClips = clips.filter(\.isEnabled)
        let totalDuration = enabledClips.reduce(0.0) { $0 + CMTimeGetSeconds($1.effectiveDuration) }
        let totalWidth = max(totalDuration * pixelsPerSecond, (superview?.bounds.width ?? 800))

        frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        spineLayer.frame = CGRect(x: 0, y: spineY, width: totalWidth, height: spineHeight)
        overlayLaneLayer.frame = CGRect(x: 0, y: overlayY, width: totalWidth, height: overlayHeight)

        layoutSpine(totalWidth: totalWidth)
        layoutOverlays()
        layoutZones()

        let phx = CGFloat(playheadSeconds * pixelsPerSecond)
        playheadLayer.frame = CGRect(x: phx - 1, y: 0, width: 2, height: totalHeight)

        if playheadLayer.sublayers?.isEmpty ?? true {
            let triangle = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -6, y: totalHeight))
            path.addLine(to: CGPoint(x: 7, y: totalHeight))
            path.addLine(to: CGPoint(x: 0.5, y: totalHeight - 10))
            path.closeSubpath()
            triangle.path = path
            triangle.fillColor = NSColor.red.cgColor
            playheadLayer.addSublayer(triangle)
        }

        CATransaction.commit()
    }

    private func layoutSpine(totalWidth: CGFloat) {
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
                spineLayer.addSublayer(clipLayer)
            }

            clipLayer.frame = CGRect(x: x, y: 0, width: max(width, 3), height: spineHeight)
            clipLayer.backgroundColor = (selectedClipId == clip.id)
                ? NSColor.systemBlue.cgColor
                : NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            clipLayer.borderColor = (selectedClipId == clip.id)
                ? NSColor.white.cgColor
                : NSColor.black.withAlphaComponent(0.2).cgColor
            clipLayer.borderWidth = selectedClipId == clip.id ? 2 : 0.5

            if let textLayer = clipLayer.sublayers?.first as? CATextLayer {
                let dur = CMTimeGetSeconds(clip.effectiveDuration)
                let time = dur < 1 ? String(format: "%.0fms", dur * 1000) : String(format: "%.1fs", dur)
                // Имя источника показываем, только когда роликов больше одного —
                // иначе подпись на каждом клипе просто шумит
                let name = sourceNames.count > 1 ? (sourceNames[clip.sourceID] ?? "") : ""
                textLayer.string = name.isEmpty ? time : "\(name) · \(time)"
                textLayer.frame = CGRect(x: 4, y: (spineHeight - 16) / 2, width: max(width - 8, 0), height: 16)
                textLayer.isHidden = width < 40
            }

            let isSelected = selectedClipId == clip.id
            let handleColor = isSelected
                ? NSColor.systemYellow.cgColor
                : NSColor.white.withAlphaComponent(0.5).cgColor
            let handleW: CGFloat = isSelected ? 5 : 3

            if let leftHandle = clipLayer.sublayers?[safe: 1] {
                leftHandle.frame = CGRect(x: 0, y: 0, width: handleW, height: spineHeight)
                leftHandle.backgroundColor = handleColor
                leftHandle.cornerRadius = 1.5
            }
            if let rightHandle = clipLayer.sublayers?[safe: 2] {
                rightHandle.frame = CGRect(x: max(width - handleW, 0), y: 0, width: handleW, height: spineHeight)
                rightHandle.backgroundColor = handleColor
                rightHandle.cornerRadius = 1.5
            }

            drawWaveform(for: clip, in: clipLayer, width: width)
            x += width
        }

        for (id, layer) in clipLayers where !activeIds.contains(id) {
            layer.removeFromSuperlayer()
            clipLayers.removeValue(forKey: id)
        }
    }

    /// Волна берётся у источника этого клипа и режется по его диапазону:
    /// одна волна на весь таймлайн врала бы, как только роликов стало больше одного
    private func drawWaveform(for clip: TimelineClip, in clipLayer: CALayer, width: CGFloat) {
        guard let waveform = waveforms[clip.sourceID] else {
            (clipLayer.sublayers?[safe: 3] as? CAShapeLayer)?.path = nil
            return
        }

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
        waveLayer.frame = CGRect(x: 0, y: 0, width: width, height: spineHeight)

        let path = CGMutablePath()
        let midY = spineHeight / 2
        let amp = spineHeight / 2 * 0.85
        let startSample = Int(CMTimeGetSeconds(clip.sourceRange.start) * Double(waveform.samplesPerSecond))
        let endSample = Int(CMTimeGetSeconds(CMTimeRangeGetEnd(clip.sourceRange)) * Double(waveform.samplesPerSecond))
        let sampleCount = max(1, endSample - startSample)

        for si in max(0, startSample)..<min(endSample, waveform.peaks.count) {
            let progress = CGFloat(si - startSample) / CGFloat(sampleCount)
            let px = progress * width
            let h = CGFloat(waveform.peaks[si]) * amp
            path.move(to: CGPoint(x: px, y: midY - h))
            path.addLine(to: CGPoint(x: px, y: midY + h))
        }
        waveLayer.path = path
    }

    private func layoutOverlays() {
        var activeIds = Set<UUID>()

        for overlay in overlays where overlay.isEnabled {
            activeIds.insert(overlay.id)
            let x = CGFloat(CMTimeGetSeconds(overlay.timelineStart) * pixelsPerSecond)
            let width = CGFloat(CMTimeGetSeconds(overlay.sourceRange.duration) * pixelsPerSecond)

            let layer: CALayer
            if let existing = overlayLayers[overlay.id] {
                layer = existing
            } else {
                layer = makeOverlayLayer()
                overlayLayers[overlay.id] = layer
                overlayLaneLayer.addSublayer(layer)
            }

            let isSelected = selectedOverlayId == overlay.id
            layer.frame = CGRect(x: x, y: 0, width: max(width, 3), height: overlayHeight)
            layer.backgroundColor = isSelected
                ? NSColor.systemPurple.cgColor
                : NSColor.systemPurple.withAlphaComponent(0.65).cgColor
            layer.borderColor = isSelected
                ? NSColor.white.cgColor
                : NSColor.black.withAlphaComponent(0.25).cgColor
            layer.borderWidth = isSelected ? 2 : 0.5

            if let textLayer = layer.sublayers?.first as? CATextLayer {
                textLayer.string = sourceNames[overlay.sourceID] ?? "перебивка"
                textLayer.frame = CGRect(x: 6, y: (overlayHeight - 14) / 2, width: max(width - 12, 0), height: 14)
                textLayer.isHidden = width < 40
            }

            let handleColor = isSelected
                ? NSColor.systemYellow.cgColor
                : NSColor.white.withAlphaComponent(0.5).cgColor
            let handleW: CGFloat = isSelected ? 5 : 3
            if let leftHandle = layer.sublayers?[safe: 1] {
                leftHandle.frame = CGRect(x: 0, y: 0, width: handleW, height: overlayHeight)
                leftHandle.backgroundColor = handleColor
            }
            if let rightHandle = layer.sublayers?[safe: 2] {
                rightHandle.frame = CGRect(x: max(width - handleW, 0), y: 0, width: handleW, height: overlayHeight)
                rightHandle.backgroundColor = handleColor
            }
        }

        for (id, layer) in overlayLayers where !activeIds.contains(id) {
            layer.removeFromSuperlayer()
            overlayLayers.removeValue(forKey: id)
        }
    }

    private func layoutZones() {
        // Silence zones — drawn over clips/waveform (zPosition above clip layers),
        // still below playheadLayer (zPosition 100, a sibling of spineLayer).
        var activeZoneIds = Set<UUID>()
        for zone in silenceZones {
            activeZoneIds.insert(zone.id)
            let zx = CGFloat(zone.startSeconds * pixelsPerSecond)
            let zw = max(CGFloat((zone.endSeconds - zone.startSeconds) * pixelsPerSecond), 2)

            let zoneLayer: CAShapeLayer
            if let existing = zoneLayers[zone.id] {
                zoneLayer = existing
            } else {
                zoneLayer = CAShapeLayer()
                zoneLayer.zPosition = 10
                spineLayer.addSublayer(zoneLayer)
                zoneLayers[zone.id] = zoneLayer
            }

            zoneLayer.frame = CGRect(x: zx, y: 0, width: zw, height: spineHeight)
            let zonePath = CGMutablePath()
            zonePath.addRect(CGRect(x: 0, y: 0, width: zw, height: spineHeight))
            zoneLayer.path = zonePath

            if zone.willCut {
                zoneLayer.fillColor = NSColor.systemRed.withAlphaComponent(0.28).cgColor
                zoneLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
                zoneLayer.lineWidth = 1
                zoneLayer.lineDashPattern = nil
            } else {
                zoneLayer.fillColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
                zoneLayer.strokeColor = NSColor.systemGray.withAlphaComponent(0.6).cgColor
                zoneLayer.lineWidth = 1
                zoneLayer.lineDashPattern = [4, 3]
            }
        }

        for (id, layer) in zoneLayers where !activeZoneIds.contains(id) {
            layer.removeFromSuperlayer()
            zoneLayers.removeValue(forKey: id)
        }
    }

    // Hit test: silence zone at a given X (track-local), checked across full track height.
    private func zone(at x: CGFloat) -> TimelineSilenceZone? {
        for zone in silenceZones {
            let zx = CGFloat(zone.startSeconds * pixelsPerSecond)
            let zw = max(CGFloat((zone.endSeconds - zone.startSeconds) * pixelsPerSecond), 2)
            if x >= zx && x <= zx + zw { return zone }
        }
        return nil
    }

    private func makeClipLayer() -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = 4
        layer.masksToBounds = true

        let textLayer = CATextLayer()
        textLayer.fontSize = 10
        textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .middle
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(textLayer)

        layer.addSublayer(CALayer())   // левая ручка
        layer.addSublayer(CALayer())   // правая ручка
        return layer
    }

    private func makeOverlayLayer() -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = 4
        layer.masksToBounds = true

        let textLayer = CATextLayer()
        textLayer.fontSize = 10
        textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .middle
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(textLayer)

        let left = CALayer(); left.cornerRadius = 1.5
        layer.addSublayer(left)
        let right = CALayer(); right.cornerRadius = 1.5
        layer.addSublayer(right)
        return layer
    }

    // MARK: - Geometry helpers

    private func isInOverlayLane(_ point: CGPoint) -> Bool {
        point.y >= overlayY - laneGap / 2
    }

    private func seconds(atX x: CGFloat) -> Double {
        max(0, Double(x) / pixelsPerSecond)
    }

    /// Магнит к границам клипов хребта и к плейхеду — 6 pt на текущем масштабе
    private func snapped(_ seconds: Double) -> Double {
        let threshold = 6.0 / pixelsPerSecond
        var candidates: [Double] = [playheadSeconds, 0]
        for clip in clips where clip.isEnabled {
            candidates.append(CMTimeGetSeconds(clip.timelineOffset))
            candidates.append(CMTimeGetSeconds(clip.timelineEnd))
        }
        guard let best = candidates.min(by: { abs($0 - seconds) < abs($1 - seconds) }),
              abs(best - seconds) < threshold else { return seconds }
        return best
    }

    private func overlay(at point: CGPoint) -> (overlay: OverlayClip, frame: CGRect)? {
        guard isInOverlayLane(point) else { return nil }
        let lanePoint = CGPoint(x: point.x, y: point.y - overlayY)
        for overlay in overlays where overlay.isEnabled {
            guard let layer = overlayLayers[overlay.id] else { continue }
            if layer.frame.contains(lanePoint) { return (overlay, layer.frame) }
        }
        return nil
    }

    // MARK: - Gestures

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)

        if let hit = overlay(at: point) {
            selectedOverlayId = hit.overlay.id
            selectedClipId = nil
            onSelectOverlay?(hit.overlay.id)
            onSelectClip?(nil)
            updateTimeline(clips: clips, overlays: overlays,
                           playheadPosition: CMTime(seconds: playheadSeconds, preferredTimescale: 600),
                           pixelsPerSecond: pixelsPerSecond)
            return
        }

        if isInOverlayLane(point) {
            selectedOverlayId = nil
            onSelectOverlay?(nil)
            updateTimeline(clips: clips, overlays: overlays,
                           playheadPosition: CMTime(seconds: playheadSeconds, preferredTimescale: 600),
                           pixelsPerSecond: pixelsPerSecond)
            return
        }

        let trackPoint = CGPoint(x: point.x, y: point.y - spineY)

        if !silenceZones.isEmpty, let zone = zone(at: point.x) {
            onToggleZone?(zone.id)
            return
        }

        var clickedClip: UUID? = nil
        for (id, layer) in clipLayers where layer.frame.contains(trackPoint) {
            clickedClip = id
            break
        }

        selectedOverlayId = nil
        onSelectOverlay?(nil)

        if let id = clickedClip {
            selectedClipId = id
            onSelectClip?(id)
        } else {
            selectedClipId = nil
            onSelectClip?(nil)
            onSeek?(CMTime(seconds: seconds(atX: point.x), preferredTimescale: 600))
        }

        updateTimeline(clips: clips, overlays: overlays,
                       playheadPosition: CMTime(seconds: seconds(atX: point.x), preferredTimescale: 600),
                       pixelsPerSecond: pixelsPerSecond)
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let point = gesture.location(in: self)

        switch gesture.state {
        case .began:
            if beginOverlayDrag(at: point) { return }
            if beginSpineTrim(at: point) { return }
            onSeek?(CMTime(seconds: seconds(atX: point.x), preferredTimescale: 600))

        case .changed:
            let delta = gesture.translation(in: self)
            if overlayDrag != nil {
                continueOverlayDrag(delta: delta)
            } else if trimming != nil {
                continueSpineTrim(delta: delta)
            } else {
                onSeek?(CMTime(seconds: seconds(atX: point.x), preferredTimescale: 600))
            }

        case .ended, .cancelled:
            if overlayDrag != nil { onOverlayDragEnd?() }
            if trimming != nil { onTrimEnd?() }
            overlayDrag = nil
            trimming = nil

        default: break
        }
    }

    private func beginOverlayDrag(at point: CGPoint) -> Bool {
        guard let hit = overlay(at: point) else { return false }
        let lanePoint = CGPoint(x: point.x, y: point.y - overlayY)

        let mode: OverlayDragMode
        if abs(lanePoint.x - hit.frame.minX) < handleWidth {
            mode = .left
        } else if abs(lanePoint.x - hit.frame.maxX) < handleWidth {
            mode = .right
        } else {
            mode = .move
        }

        overlayDrag = (
            id: hit.overlay.id, mode: mode,
            initialSourceRange: hit.overlay.sourceRange,
            initialStart: CMTimeGetSeconds(hit.overlay.timelineStart)
        )
        selectedOverlayId = hit.overlay.id
        selectedClipId = nil
        onSelectOverlay?(hit.overlay.id)
        onSelectClip?(nil)
        return true
    }

    private func continueOverlayDrag(delta: CGPoint) {
        guard let drag = overlayDrag else { return }
        let deltaSeconds = Double(delta.x) / pixelsPerSecond
        let sourceStart = CMTimeGetSeconds(drag.initialSourceRange.start)
        let sourceDuration = CMTimeGetSeconds(drag.initialSourceRange.duration)

        switch drag.mode {
        case .move:
            let start = max(0, snapped(drag.initialStart + deltaSeconds))
            onMoveOverlay?(drag.id, CMTime(seconds: start, preferredTimescale: 600))

        case .left:
            // Левый край тянет и начало на таймлайне, и начало куска исходника
            let start = max(0, snapped(drag.initialStart + deltaSeconds))
            let shift = start - drag.initialStart
            let newSourceStart = max(0, sourceStart + shift)
            let newDuration = max(0.05, sourceDuration - shift)
            onTrimOverlay?(
                drag.id,
                CMTimeRange(
                    start: CMTime(seconds: newSourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: newDuration, preferredTimescale: 600)
                ),
                CMTime(seconds: start, preferredTimescale: 600)
            )

        case .right:
            let end = snapped(drag.initialStart + sourceDuration + deltaSeconds)
            let newDuration = max(0.05, end - drag.initialStart)
            onTrimOverlay?(
                drag.id,
                CMTimeRange(
                    start: drag.initialSourceRange.start,
                    duration: CMTime(seconds: newDuration, preferredTimescale: 600)
                ),
                CMTime(seconds: drag.initialStart, preferredTimescale: 600)
            )
        }
    }

    private func beginSpineTrim(at point: CGPoint) -> Bool {
        let trackPoint = CGPoint(x: point.x, y: point.y - spineY)
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
            } else if abs(trackPoint.x - frame.maxX) < handleWidth {
                trimming = (clipId: clip.id, edge: .right, initialRange: clip.sourceRange)
            } else {
                continue
            }
            selectedClipId = clip.id
            onSelectClip?(clip.id)
            return true
        }
        return false
    }

    private func continueSpineTrim(delta: CGPoint) {
        guard let trim = trimming,
              let clipIdx = clips.firstIndex(where: { $0.id == trim.clipId }) else { return }
        let clip = clips[clipIdx]
        let timeDelta = CMTime(seconds: Double(delta.x) / pixelsPerSecond, preferredTimescale: 600)

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
                duration: CMTimeMinimum(
                    CMTimeMaximum(CMTime(seconds: 0.1, preferredTimescale: 600), newDuration),
                    maxDuration
                )
            )
        }

        onTrimClip?(trim.clipId, newRange)
    }

    // MARK: - Drag & Drop из Finder

    private var dropTargetIsOverlayLane: Bool?

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(sender)
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(sender)
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropHighlight()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropHighlight()
    }

    private func updateDropHighlight(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        let overlayLane = isInOverlayLane(point)
        guard dropTargetIsOverlayLane != overlayLane else { return }
        dropTargetIsOverlayLane = overlayLane

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLaneLayer.borderWidth = overlayLane ? 2 : 0
        overlayLaneLayer.borderColor = NSColor.systemPurple.cgColor
        spineLayer.borderWidth = overlayLane ? 0 : 2
        spineLayer.borderColor = NSColor.systemGreen.cgColor
        CATransaction.commit()
    }

    private func clearDropHighlight() {
        dropTargetIsOverlayLane = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayLaneLayer.borderWidth = 0
        spineLayer.borderWidth = 0
        CATransaction.commit()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropHighlight() }
        guard let onDropFile else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        let point = convert(sender.draggingLocation, from: nil)
        let toOverlayLane = isInOverlayLane(point)
        let time = CMTime(seconds: snapped(seconds(atX: point.x)), preferredTimescale: 600)

        for url in urls {
            onDropFile(url, time, toOverlayLane)
        }
        return true
    }

    // MARK: - Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: break // Space — handled by SwiftUI
        case 51:
            if selectedOverlayId != nil {
                onSelectOverlay?(nil)
                selectedOverlayId = nil
            } else if selectedClipId != nil {
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

        if let hit = overlay(at: point) {
            _ = hit
            let lanePoint = CGPoint(x: point.x, y: point.y - overlayY)
            let onEdge = abs(lanePoint.x - hit.frame.minX) < handleWidth
                || abs(lanePoint.x - hit.frame.maxX) < handleWidth
            (onEdge ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
            return
        }

        let trackPoint = CGPoint(x: point.x, y: point.y - spineY)
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
        if onHandle {
            NSCursor.resizeLeftRight.set()
        } else if !silenceZones.isEmpty && zone(at: point.x) != nil {
            NSCursor.pointingHand.set()
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
    let overlays: [OverlayClip]
    let playheadPosition: CMTime
    let pixelsPerSecond: Double
    let waveforms: [UUID: WaveformData]
    let sourceNames: [UUID: String]
    let onSeek: (CMTime) -> Void
    let onTrimClip: (UUID, CMTimeRange) -> Void
    let onTrimEnd: () -> Void
    let onSelectClip: (UUID?) -> Void
    let silenceZones: [TimelineSilenceZone]
    let onToggleZone: ((UUID) -> Void)?

    // На iOS перебивки только показываются: редактирование второй дорожки — на macOS
    public init(
        clips: [TimelineClip],
        overlays: [OverlayClip] = [],
        playheadPosition: CMTime,
        pixelsPerSecond: Double,
        waveforms: [UUID: WaveformData] = [:],
        sourceNames: [UUID: String] = [:],
        selectedClipId: UUID? = nil,
        selectedOverlayId: UUID? = nil,
        onSeek: @escaping (CMTime) -> Void,
        onTrimClip: @escaping (UUID, CMTimeRange) -> Void,
        onTrimEnd: @escaping () -> Void = {},
        onSelectClip: @escaping (UUID?) -> Void,
        silenceZones: [TimelineSilenceZone] = [],
        onToggleZone: ((UUID) -> Void)? = nil,
        onSelectOverlay: ((UUID?) -> Void)? = nil,
        onDropFile: ((URL, CMTime, Bool) -> Void)? = nil,
        onMoveOverlay: ((UUID, CMTime) -> Void)? = nil,
        onTrimOverlay: ((UUID, CMTimeRange, CMTime) -> Void)? = nil,
        onOverlayDragEnd: (() -> Void)? = nil
    ) {
        self.clips = clips
        self.overlays = overlays
        self.playheadPosition = playheadPosition
        self.pixelsPerSecond = pixelsPerSecond
        self.waveforms = waveforms
        self.sourceNames = sourceNames
        self.onSeek = onSeek
        self.onTrimClip = onTrimClip
        self.onTrimEnd = onTrimEnd
        self.onSelectClip = onSelectClip
        self.silenceZones = silenceZones
        self.onToggleZone = onToggleZone
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
        timeline.onToggleZone = onToggleZone
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
        timeline.onToggleZone = onToggleZone
        timeline.updateTimeline(
            clips: clips,
            overlays: overlays,
            playheadPosition: playheadPosition,
            pixelsPerSecond: pixelsPerSecond,
            waveforms: waveforms,
            silenceZones: silenceZones,
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
    var onToggleZone: ((UUID) -> Void)?

    private var clips: [TimelineClip] = []
    private var overlays: [OverlayClip] = []
    private var pixelsPerSecond: Double = 100
    private var selectedClipId: UUID?
    private var waveforms: [UUID: WaveformData] = [:]
    private var silenceZones: [TimelineSilenceZone] = []

    private let trackLayer = CALayer()
    private let playheadLayer = CALayer()
    private var clipLayers: [UUID: CALayer] = [:]
    private var zoneLayers: [UUID: CAShapeLayer] = [:]

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

    func updateTimeline(clips: [TimelineClip], overlays: [OverlayClip] = [], playheadPosition: CMTime, pixelsPerSecond: Double, waveforms: [UUID: WaveformData]? = nil, silenceZones: [TimelineSilenceZone]? = nil, scrollViewWidth: CGFloat = 400) {
        self.clips = clips
        self.overlays = overlays
        self.pixelsPerSecond = pixelsPerSecond
        if let waveforms { self.waveforms = waveforms }
        if let zones = silenceZones { self.silenceZones = zones }

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

            if let waveform = waveforms[clip.sourceID] {
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

        // Silence zones — drawn over clips/waveform (zPosition above clip layers),
        // still below playheadLayer (zPosition 100, a sibling of trackLayer).
        var activeZoneIds = Set<UUID>()
        for zone in self.silenceZones {
            activeZoneIds.insert(zone.id)
            let zx = CGFloat(zone.startSeconds * pixelsPerSecond)
            let zw = max(CGFloat((zone.endSeconds - zone.startSeconds) * pixelsPerSecond), 2)

            let zoneLayer: CAShapeLayer
            if let existing = zoneLayers[zone.id] {
                zoneLayer = existing
            } else {
                zoneLayer = CAShapeLayer()
                zoneLayer.zPosition = 10
                trackLayer.addSublayer(zoneLayer)
                zoneLayers[zone.id] = zoneLayer
            }

            zoneLayer.frame = CGRect(x: zx, y: 0, width: zw, height: trackHeight)
            let zonePath = CGMutablePath()
            zonePath.addRect(CGRect(x: 0, y: 0, width: zw, height: trackHeight))
            zoneLayer.path = zonePath

            if zone.willCut {
                zoneLayer.fillColor = UIColor.systemRed.withAlphaComponent(0.28).cgColor
                zoneLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.6).cgColor
                zoneLayer.lineWidth = 1
                zoneLayer.lineDashPattern = nil
            } else {
                zoneLayer.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor
                zoneLayer.strokeColor = UIColor.systemGray.withAlphaComponent(0.6).cgColor
                zoneLayer.lineWidth = 1
                zoneLayer.lineDashPattern = [4, 3]
            }
        }

        for (id, layer) in zoneLayers where !activeZoneIds.contains(id) {
            layer.removeFromSuperlayer()
            zoneLayers.removeValue(forKey: id)
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

    // Hit test: silence zone at a given X (track-local), checked across full track height.
    private func zone(at x: CGFloat) -> TimelineSilenceZone? {
        for zone in silenceZones {
            let zx = CGFloat(zone.startSeconds * pixelsPerSecond)
            let zw = max(CGFloat((zone.endSeconds - zone.startSeconds) * pixelsPerSecond), 2)
            if x >= zx && x <= zx + zw { return zone }
        }
        return nil
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

        if !silenceZones.isEmpty, let zone = zone(at: point.x) {
            onToggleZone?(zone.id)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

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
