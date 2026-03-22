import SwiftUI
import AVFoundation

private struct FragmentLayout: Identifiable {
    let id: UUID
    let fragment: TimelineFragment
    let x: CGFloat
    let width: CGFloat
}

struct TimelineContainerView: View {
    @Bindable var engine: TimelineEngine
    let waveformData: WaveformGenerator.WaveformData?
    let player: AVPlayer?
    let sourceDuration: Double

    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var boundaryObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    private var displayDuration: Double {
        engine.fragments.isEmpty ? sourceDuration : engine.totalDuration
    }

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()
            timelineArea
        }
        .onAppear { setupTimeObserver() }
        .onDisappear { removeAllObservers() }
        // Fix #1: re-setup time observer when player changes (was nil on first onAppear)
        .onChange(of: player?.currentItem) { _, _ in
            removeAllObservers()
            setupTimeObserver()
        }
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button { seekTo(0) } label: {
                Image(systemName: "backward.end.fill")
            }.buttonStyle(.plain)

            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button { seekTo(displayDuration) } label: {
                Image(systemName: "forward.end.fill")
            }.buttonStyle(.plain)

            Divider().frame(height: 16)

            Text(formatTimecode(engine.playheadPosition))
                .font(.system(.body, design: .monospaced))

            Text("/ \(formatTimecode(displayDuration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if engine.fragments.isEmpty && sourceDuration > 0 {
                Text("(click Detect Silence)")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button { engine.pixelsPerSecond = max(20, engine.pixelsPerSecond * 0.8) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.buttonStyle(.plain)
                Slider(value: $engine.pixelsPerSecond, in: 20...500).frame(width: 120)
                Button { engine.pixelsPerSecond = min(500, engine.pixelsPerSecond * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Timeline Area

    private var timelineArea: some View {
        GeometryReader { geo in
            let pps = engine.pixelsPerSecond
            let dur = displayDuration
            let totalWidth = max(dur * pps, Double(geo.size.width))
            let trackH = geo.size.height - 8.0
            let layouts = computeLayouts(pps: pps)

            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Layer 1: Fragments + waveform (Canvas — redraws only when fragments change)
                    Canvas { context, size in
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .color(Color(nsColor: .controlBackgroundColor))
                        )

                        for layout in layouts {
                            let rect = CGRect(x: layout.x, y: 4, width: layout.width, height: trackH)
                            let path = Path(roundedRect: rect, cornerRadius: 3)
                            let isSelected = engine.selectedFragmentID == layout.fragment.id

                            let color: Color = isSelected ? .blue
                                : layout.fragment.type == .speech ? .green.opacity(0.6) : .red.opacity(0.4)

                            context.fill(path, with: .color(color))
                            context.stroke(path, with: .color(isSelected ? .white : .black.opacity(0.2)),
                                           lineWidth: isSelected ? 2 : 0.5)

                            if layout.width > 50 {
                                let text = Text("\(layout.fragment.type == .speech ? "Speech" : "Silence")\n\(formatDuration(layout.fragment.sourceDuration))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.8))
                                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
                            }
                        }

                        if let waveform = waveformData, !layouts.isEmpty {
                            drawWaveform(context: context, waveform: waveform, layouts: layouts, height: trackH, pps: pps)
                        }
                    }

                    // Layer 2: Playhead (separate View struct — re-renders independently)
                    PlayheadIndicator(engine: engine, pps: pps, height: geo.size.height)
                }
                .frame(width: totalWidth, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let time = max(0, min(location.x / pps, dur))
                    seekTo(time)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Waveform

    private func drawWaveform(
        context: GraphicsContext, waveform: WaveformGenerator.WaveformData,
        layouts: [FragmentLayout], height: CGFloat, pps: Double
    ) {
        var path = Path()
        let midY = height / 2 + 4
        let amp = height / 2 * 0.85
        for layout in layouts {
            let frag = layout.fragment
            let startS = Int(frag.sourceStartTime * Double(waveform.samplesPerSecond))
            let endS = Int(frag.sourceEndTime * Double(waveform.samplesPerSecond))
            for si in startS..<min(endS, waveform.samples.count) {
                let prog = Double(si - startS) / Double(max(1, endS - startS))
                let x = layout.x + prog * layout.width
                let h = CGFloat(waveform.samples[si]) * amp
                path.move(to: CGPoint(x: x, y: midY - h))
                path.addLine(to: CGPoint(x: x, y: midY + h))
            }
        }
        context.stroke(path, with: .color(.primary.opacity(0.3)), lineWidth: 1)
    }

    // MARK: - Layout

    private func computeLayouts(pps: Double) -> [FragmentLayout] {
        var result: [FragmentLayout] = []
        var x: CGFloat = 0
        for fragment in engine.fragments where fragment.isIncluded {
            let w = max(fragment.sourceDuration * pps, 3)
            result.append(FragmentLayout(id: fragment.id, fragment: fragment, x: x, width: w))
            x += w
        }
        return result
    }

    // MARK: - Time Conversion (edit time ↔ source time)

    /// Convert timeline position (edit time) to source file position
    private func editTimeToSourceTime(_ editTime: Double) -> Double {
        var remaining = editTime
        for fragment in engine.fragments where fragment.isIncluded {
            if remaining <= fragment.sourceDuration {
                return fragment.sourceStartTime + remaining
            }
            remaining -= fragment.sourceDuration
        }
        return engine.fragments.last?.sourceEndTime ?? editTime
    }

    /// Convert source file position to timeline position (edit time)
    private func sourceTimeToEditTime(_ sourceTime: Double) -> Double {
        var editTime: Double = 0
        for fragment in engine.fragments where fragment.isIncluded {
            if sourceTime < fragment.sourceStartTime {
                break
            } else if sourceTime < fragment.sourceEndTime {
                editTime += sourceTime - fragment.sourceStartTime
                break
            } else {
                editTime += fragment.sourceDuration
            }
        }
        return editTime
    }

    /// Find the next included fragment that starts at or after the given source time
    private func nextIncludedFragment(after sourceTime: Double) -> TimelineFragment? {
        for fragment in engine.fragments where fragment.isIncluded {
            // Find first included fragment whose end is after current position
            if fragment.sourceEndTime > sourceTime {
                return fragment
            }
        }
        return nil
    }

    // MARK: - Playback

    private func seekTo(_ editTime: Double) {
        let clamped = max(0, min(editTime, displayDuration))
        engine.playheadPosition = clamped

        // Only update playhead position visually — don't seek the player
        // (seeking causes err=-12860). Player seek only on play.
    }

    private func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            playFromCurrentPosition()
        }
    }

    /// Start playback from the current playhead position
    /// Sets up boundary observers to skip silence regions
    private func playFromCurrentPosition() {
        guard let player = player else { return }

        let included = engine.fragments.filter { $0.isIncluded }
        guard !included.isEmpty else {
            // No fragments — just play normally
            player.play()
            isPlaying = true
            return
        }

        // Find which included fragment corresponds to current playhead position
        let editTime = engine.playheadPosition
        let sourceTime = editTimeToSourceTime(editTime)

        // Seek to the correct source position and play
        player.seek(to: CMTime(seconds: sourceTime, preferredTimescale: 600)) { _ in
            // Set up boundary observers at the END of each included fragment
            // When player reaches the end of a speech segment, skip to next
            self.setupBoundaryObservers()
            player.play()
            self.isPlaying = true
        }
    }

    /// Set up boundary time observers at the end of each included fragment
    private func setupBoundaryObservers() {
        // Remove old boundary observer
        if let obs = boundaryObserver {
            player?.removeTimeObserver(obs)
            boundaryObserver = nil
        }

        guard let player = player else { return }
        let included = engine.fragments.filter { $0.isIncluded }
        guard !included.isEmpty else { return }

        // Build pairs: (fragmentEndTime, nextFragmentStartTime)
        // For last fragment: end → stop playback
        var skipTargets: [(boundaryTime: Double, seekTo: Double?)] = []
        for i in 0..<included.count {
            let endTime = included[i].sourceEndTime
            if i + 1 < included.count {
                skipTargets.append((boundaryTime: endTime, seekTo: included[i + 1].sourceStartTime))
            } else {
                skipTargets.append((boundaryTime: endTime, seekTo: nil)) // stop
            }
        }

        let boundaryTimes = skipTargets.map {
            NSValue(time: CMTime(seconds: $0.boundaryTime, preferredTimescale: 600))
        }

        // Use a class to safely track state in the closure
        class SkipState { var nextIndex = 0 }
        let state = SkipState()

        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: boundaryTimes,
            queue: .main
        ) { [self] in
            let idx = state.nextIndex
            guard idx < skipTargets.count else { return }
            state.nextIndex += 1

            if let seekTo = skipTargets[idx].seekTo {
                print("[Timeline] Skip \(idx + 1)/\(skipTargets.count): seek to \(String(format: "%.1f", seekTo))s")
                player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600))
            } else {
                // Last fragment ended — stop
                print("[Timeline] Playback complete")
                player.pause()
                isPlaying = false
                engine.playheadPosition = 0 // reset to start
            }
        }

        // Fix #3: Remove old NotificationCenter observer before adding new one
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
            endObserver = nil
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [self] _ in
            print("[Timeline] Player reached end of file")
            player.pause()
            isPlaying = false
            engine.playheadPosition = 0
        }
    }

    private func setupTimeObserver() {
        guard let player = player else { return }
        let interval = CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600) // 15fps for display
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard isPlaying else { return }
            let sourceTime = CMTimeGetSeconds(time)

            if engine.fragments.isEmpty {
                engine.playheadPosition = sourceTime
            } else {
                // Just update the playhead display — silence skipping is handled by boundary observers
                engine.playheadPosition = sourceTimeToEditTime(sourceTime)
            }
        }
    }

    private func removeAllObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let obs = boundaryObserver {
            player?.removeTimeObserver(obs)
            boundaryObserver = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }

    // MARK: - Formatting

    private func formatTimecode(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        let f = Int((seconds.truncatingRemainder(dividingBy: 1)) * 30)
        return String(format: "%02d:%02d:%02d", m, s, f)
    }

    private func formatDuration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0fms", seconds * 1000) : String(format: "%.1fs", seconds)
    }
}

// MARK: - Playhead Indicator (separate view for independent re-rendering)

struct PlayheadIndicator: View {
    @Bindable var engine: TimelineEngine
    let pps: Double
    let height: CGFloat

    var body: some View {
        let x = engine.playheadPosition * pps
        ZStack(alignment: .topLeading) {
            // Vertical line
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
                .offset(x: x - 1)

            // Triangle handle at top
            Canvas { ctx, _ in
                var tri = Path()
                tri.move(to: CGPoint(x: x - 7, y: 0))
                tri.addLine(to: CGPoint(x: x + 7, y: 0))
                tri.addLine(to: CGPoint(x: x, y: 10))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(.red))
            }
            .frame(height: 12)
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.05), value: engine.playheadPosition)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in if inside { cursor.push() } else { NSCursor.pop() } }
    }
}
