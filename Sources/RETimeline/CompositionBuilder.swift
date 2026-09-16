import Foundation
import AVFoundation
import RECore

/// Builds a disposable AVMutableComposition from the EDL model.
/// Called on every timeline change. Cost: <1ms for dozens of clips.
public enum CompositionBuilder {

    public struct Result {
        public let composition: AVMutableComposition
        public let videoComposition: AVMutableVideoComposition?
        public let audioMix: AVMutableAudioMix?
    }

    /// Build composition from timeline — the core function.
    /// `options` drive framing (aspect crop), jump-cut zoom and audio gain;
    /// preview and export both go through here, so what you see is what you get.
    ///
    /// Дорожек три: видео хребта, видео перебивок, звук хребта. Перебивки живут на своей
    /// дорожке, а не врезаются в хребет — сборщику не нужно нарезать хребет вокруг каждой
    /// картинки, и звук речи под перебивкой не прерывается.
    public static func build(
        from timeline: EditTimeline,
        options: RenderOptions = .default
    ) async throws -> Result {
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BuildError.cannotCreateTrack }

        var audioTrack = composition.addMutableTrack(
            withMediaType: AVMediaType.audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        let renderSize = projectRenderSize(timeline: timeline, options: options)
        let spine = timeline.clips.filter(\.isEnabled)

        // Куда какой клип встал и с каким кадрированием — нужно для трансформаций и рамп
        struct Placed {
            let start: CMTime
            let duration: Double
            let framing: ClipFraming
            let orientedSize: CGSize
            let sourceTransform: CGAffineTransform
            let gain: Double
            let framingEnd: ClipFraming?
        }
        var placed: [Placed] = []
        var insertionTime = CMTime.zero

        for clip in spine {
            guard let source = timeline.source(for: clip.sourceID) else { continue }
            let asset = AVURLAsset(url: source.url)

            let videoTracks = try await asset.loadTracks(withMediaType: AVMediaType.video)
            guard let srcVideo = videoTracks.first else { continue }
            try videoTrack.insertTimeRange(clip.sourceRange, of: srcVideo, at: insertionTime)

            // Звук: у немого исходника вставляем пустоту той же длины. Раньше источник был
            // один и расхождению неоткуда было взяться; с разными файлами пропуск вставки
            // уводит весь звук после этого клипа.
            if let dstAudio = audioTrack {
                let audioTracks = try await asset.loadTracks(withMediaType: AVMediaType.audio)
                if let srcAudio = audioTracks.first {
                    try dstAudio.insertTimeRange(clip.sourceRange, of: srcAudio, at: insertionTime)
                } else {
                    dstAudio.insertEmptyTimeRange(
                        CMTimeRange(start: insertionTime, duration: clip.effectiveDuration)
                    )
                }
            }

            placed.append(Placed(
                start: insertionTime,
                duration: CMTimeGetSeconds(clip.effectiveDuration),
                framing: clip.framing,
                orientedSize: source.orientedSize,
                sourceTransform: source.preferredTransform,
                // Гейн источника умножается на гейн клипа: файл может быть тише целиком,
                // а внутри него отдельная реплика — ещё тише, если микрофон пропал
                gain: source.gain * clip.gain,
                framingEnd: clip.framingEnd
            ))
            insertionTime = CMTimeAdd(insertionTime, clip.effectiveDuration)
        }

        // Источник без звука — пустая аудиодорожка ломает AVAssetReader при экспорте, убираем её.
        // У незаполненной дорожки timeRange невалиден, поэтому сравнение с .zero тут не годится.
        if let track = audioTrack {
            let seconds = CMTimeGetSeconds(track.timeRange.duration)
            if !seconds.isFinite || seconds <= 0 {
                composition.removeTrack(track)
                audioTrack = nil
            }
        }

        // === Перебивки ===
        struct PlacedOverlay {
            let range: CMTimeRange
            let framing: ClipFraming
            let orientedSize: CGSize
            let sourceTransform: CGAffineTransform
        }
        var placedOverlays: [PlacedOverlay] = []
        var overlayTrack: AVMutableCompositionTrack?

        let overlays = timeline.clampedOverlays.sorted {
            CMTimeCompare($0.timelineStart, $1.timelineStart) < 0
        }
        if !overlays.isEmpty, !placed.isEmpty {
            overlayTrack = composition.addMutableTrack(
                withMediaType: AVMediaType.video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            var overlayCursor = CMTime.zero
            for overlay in overlays {
                guard let source = timeline.source(for: overlay.sourceID),
                      let track = overlayTrack else { continue }
                // Перебивки не должны наезжать друг на друга: то, что началось раньше, остаётся
                guard CMTimeCompare(overlay.timelineStart, overlayCursor) >= 0 else { continue }

                let asset = AVURLAsset(url: source.url)
                let videoTracks = try await asset.loadTracks(withMediaType: AVMediaType.video)
                guard let srcVideo = videoTracks.first else { continue }

                // Дорожка заполняется подряд, поэтому промежуток до перебивки — пустой диапазон
                let gap = CMTimeSubtract(overlay.timelineStart, overlayCursor)
                if CMTimeGetSeconds(gap) > 0.001 {
                    track.insertEmptyTimeRange(CMTimeRange(start: overlayCursor, duration: gap))
                }
                try track.insertTimeRange(overlay.sourceRange, of: srcVideo, at: overlay.timelineStart)

                placedOverlays.append(PlacedOverlay(
                    range: overlay.timelineRange,
                    framing: overlay.framing,
                    orientedSize: source.orientedSize,
                    sourceTransform: source.preferredTransform
                ))
                overlayCursor = overlay.timelineEnd
            }
            if placedOverlays.isEmpty {
                composition.removeTrack(overlayTrack!)
                overlayTrack = nil
            }
        }

        // === Дорожки графики: титры с альфой поверх всего ===
        //
        // Дорожек столько, сколько нужно. Раньше она была одна, и наехавший по времени
        // титр молча пропадал — а именно так и выглядит рабочий случай: бегущая строка
        // идёт через весь ролик, подписи говорящих появляются поверх неё.
        //
        // Раскладка жадная: клип занимает первую дорожку, которая к его началу уже
        // освободилась, иначе заводится новая. Для десятка титров этого достаточно, а
        // оптимальная упаковка тут не нужна — лишняя дорожка стоит дёшево.
        struct GraphicTrack {
            let track: AVMutableCompositionTrack
            var cursor: CMTime
            var ranges: [CMTimeRange]
        }
        var graphicTracks: [GraphicTrack] = []

        let graphics = timeline.clampedGraphics.sorted {
            CMTimeCompare($0.timelineStart, $1.timelineStart) < 0
        }
        if !graphics.isEmpty, !placed.isEmpty {
            for graphic in graphics {
                guard let source = timeline.source(for: graphic.sourceID) else { continue }
                let asset = AVURLAsset(url: source.url)
                let videoTracks = try await asset.loadTracks(withMediaType: AVMediaType.video)
                guard let srcVideo = videoTracks.first else { continue }

                var slot = graphicTracks.firstIndex {
                    CMTimeCompare(graphic.timelineStart, $0.cursor) >= 0
                }
                if slot == nil {
                    guard let track = composition.addMutableTrack(
                        withMediaType: AVMediaType.video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else { continue }
                    graphicTracks.append(GraphicTrack(track: track, cursor: .zero, ranges: []))
                    slot = graphicTracks.count - 1
                }
                guard let index = slot else { continue }

                // Дорожка заполняется подряд, поэтому промежуток до титра — пустой диапазон
                let gap = CMTimeSubtract(graphic.timelineStart, graphicTracks[index].cursor)
                if CMTimeGetSeconds(gap) > 0.001 {
                    graphicTracks[index].track.insertEmptyTimeRange(
                        CMTimeRange(start: graphicTracks[index].cursor, duration: gap)
                    )
                }
                try graphicTracks[index].track.insertTimeRange(
                    graphic.sourceRange, of: srcVideo, at: graphic.timelineStart
                )
                graphicTracks[index].ranges.append(graphic.timelineRange)
                graphicTracks[index].cursor = graphic.timelineEnd
            }
            graphicTracks.removeAll { entry in
                guard entry.ranges.isEmpty else { return false }
                composition.removeTrack(entry.track)
                return true
            }
        }

        // === Видеокомпозиция: ориентация, кадрирование, джамп-кат зум, перебивки ===
        var videoComp: AVMutableVideoComposition? = nil

        if !placed.isEmpty {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: insertionTime)

            let spineLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            // Step change at cuts where the zoom actually differs — no interpolation,
            // and no redundant transforms while the scale is being held
            let scales = options.zoomScales(forClipDurations: placed.map(\.duration))
            var appliedTransform: CGAffineTransform? = nil
            for (index, item) in placed.enumerated() {
                let transform = renderTransform(
                    sourceTransform: item.sourceTransform,
                    orientedSize: item.orientedSize,
                    targetSize: renderSize,
                    framing: item.framing,
                    zoom: scales[index]
                )

                // Кадр едет внутри клипа: ведём человека, который смещается и приближается.
                // Ramp, а не пара setTransform: последний даёт ступеньку, то есть рывок.
                if let end = item.framingEnd {
                    let endTransform = renderTransform(
                        sourceTransform: item.sourceTransform,
                        orientedSize: item.orientedSize,
                        targetSize: renderSize,
                        framing: end,
                        zoom: scales[index]
                    )
                    spineLayer.setTransformRamp(
                        fromStart: transform,
                        toEnd: endTransform,
                        timeRange: CMTimeRange(
                            start: item.start,
                            duration: CMTime(seconds: item.duration, preferredTimescale: 600)
                        )
                    )
                    // Рампа сама задаёт значение на всём отрезке — следующий клип
                    // обязан выставить своё, поэтому запомненное сбрасываем
                    appliedTransform = nil
                    continue
                }

                guard appliedTransform != transform else { continue }
                spineLayer.setTransform(transform, at: item.start)
                appliedTransform = transform
            }

            var layers = [spineLayer]

            if let overlayTrack {
                let overlayLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: overlayTrack)
                // Вне своих диапазонов дорожка пустая, но опасити гасим явно: так кадр
                // не зависит от того, что компоновщик решит делать с дыркой в дорожке
                overlayLayer.setOpacity(0, at: .zero)
                for item in placedOverlays {
                    overlayLayer.setTransform(
                        renderTransform(
                            sourceTransform: item.sourceTransform,
                            orientedSize: item.orientedSize,
                            targetSize: renderSize,
                            framing: item.framing,
                            zoom: 1.0
                        ),
                        at: item.range.start
                    )
                    overlayLayer.setOpacity(1, at: item.range.start)
                    overlayLayer.setOpacity(0, at: CMTimeRangeGetEnd(item.range))
                }
                // Первый слой в массиве оказывается верхним — проверено на цветных фикстурах
                // в OverlayCompositionTests, документация на этот счёт невнятна.
                // Если тест начнёт падать, менять надо здесь.
                layers.insert(overlayLayer, at: 0)
            }

            // Трансформации у графики нет намеренно: титр рендерится сразу в размер
            // холста, поэтому любое масштабирование здесь только размыло бы текст.
            // Графика идёт первой — то есть поверх и хребта, и перебивок: надпись
            // должна оставаться читаемой, когда под ней b-roll. Из нескольких дорожек
            // графики верхней оказывается заведённая последней.
            for entry in graphicTracks {
                let graphicLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: entry.track)
                graphicLayer.setOpacity(0, at: .zero)
                for range in entry.ranges {
                    graphicLayer.setOpacity(1, at: range.start)
                    graphicLayer.setOpacity(0, at: CMTimeRangeGetEnd(range))
                }
                layers.insert(graphicLayer, at: 0)
            }

            instruction.layerInstructions = layers

            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(projectFrameRate(timeline: timeline)))
            vc.instructions = [instruction]
            videoComp = vc
        }

        // === Звук: рампы 30 мс на склейках плюс гейн источника и мастер-гейн ===
        var audioMix: AVMutableAudioMix? = nil
        let masterGain = max(0, options.audioGain)
        let needsGain = placed.contains { abs($0.gain * masterGain - 1.0) > 0.001 }

        if let dstAudio = audioTrack, placed.count > 1 || needsGain {
            let params = AVMutableAudioMixInputParameters(track: dstAudio)
            let fadeDuration = CMTime(seconds: 0.03, preferredTimescale: 600)

            if placed.count > 1 {
                for item in placed {
                    let gain = Float(max(0, item.gain * masterGain))
                    let segStart = item.start
                    let clipDuration = CMTime(seconds: item.duration, preferredTimescale: 600)
                    let segEnd = CMTimeAdd(segStart, clipDuration)

                    // Клип короче двух фейдов (осколок после split-clip на границе паузы):
                    // рампы входа и выхода налезли бы друг на друга, а AVFoundation на пересечение
                    // рамп бросает NSInvalidArgumentException и роняет и превью, и экспорт, и
                    // транскрибацию. Ужимаем оба фейда до половины клипа — они встречаются в
                    // середине, не пересекаясь.
                    let halfClip = CMTimeMultiplyByRatio(clipDuration, multiplier: 1, divisor: 2)
                    let fade = CMTimeCompare(fadeDuration, halfClip) > 0 ? halfClip : fadeDuration
                    guard CMTimeCompare(fade, .zero) > 0 else { continue }

                    params.setVolumeRamp(
                        fromStartVolume: 0.0, toEndVolume: gain,
                        timeRange: CMTimeRange(start: segStart, duration: fade)
                    )

                    let fadeOutStart = CMTimeSubtract(segEnd, fade)
                    if CMTimeCompare(fadeOutStart, CMTimeAdd(segStart, fade)) >= 0 {
                        params.setVolumeRamp(
                            fromStartVolume: gain, toEndVolume: 0.0,
                            timeRange: CMTimeRange(start: fadeOutStart, duration: fade)
                        )
                    }
                }
            } else if let only = placed.first {
                // Single clip — gain only
                params.setVolume(Float(max(0, only.gain * masterGain)), at: .zero)
            }

            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        return Result(composition: composition, videoComposition: videoComp, audioMix: audioMix)
    }

    // MARK: - Project Frame (pure, testable)

    /// Холст проекта. Для `.source` берётся формат первого клипа хребта: при разнородных
    /// исходниках «как в оригинале» перестаёт быть однозначным, и правило надо знать заранее.
    /// Стороны округляются до чётных — H.264 не принимает нечётные размеры.
    public static func projectRenderSize(
        timeline: EditTimeline,
        options: RenderOptions
    ) -> CGSize {
        let base: CGSize
        if let chosen = options.outputAspect.renderSize {
            base = chosen
        } else if let clip = timeline.clips.first(where: \.isEnabled),
                  let source = timeline.source(for: clip.sourceID),
                  source.orientedSize.width > 0, source.orientedSize.height > 0 {
            base = source.orientedSize
        } else {
            base = CGSize(width: 1080, height: 1920)
        }
        return CGSize(
            width: max(2, (Int(base.width) / 2) * 2),
            height: max(2, (Int(base.height) / 2) * 2)
        )
    }

    /// Частота кадров проекта — максимум по источникам хребта, зажатый в 24…60.
    /// Источники с другой частотой компоновщик приведёт сам.
    public static func projectFrameRate(timeline: EditTimeline) -> Int {
        let rates = timeline.clips
            .filter(\.isEnabled)
            .compactMap { timeline.source(for: $0.sourceID)?.nominalFrameRate }
            .filter { $0 > 1 }
        let best = rates.max() ?? 30
        return max(24, min(60, Int(best.rounded())))
    }

    // MARK: - Transform Math (pure, testable)

    /// Transform placing an oriented source frame into the target frame:
    /// source orientation → aspect-fill scale (center crop) → кадрирование клипа → zoom about the center.
    public static func renderTransform(
        sourceTransform: CGAffineTransform,
        orientedSize: CGSize,
        targetSize: CGSize,
        framing: ClipFraming = .default,
        zoom: Double
    ) -> CGAffineTransform {
        guard orientedSize.width > 0, orientedSize.height > 0 else { return sourceTransform }

        let fillScale = max(targetSize.width / orientedSize.width,
                            targetSize.height / orientedSize.height)
        let scale = fillScale * CGFloat(max(0.01, framing.scale)) * CGFloat(max(0.01, zoom))

        // Center the scaled frame in the target — crops the overflow symmetrically,
        // затем ручной сдвиг кадрировщика в долях холста
        let tx = (targetSize.width - orientedSize.width * scale) / 2 + framing.offset.x * targetSize.width
        let ty = (targetSize.height - orientedSize.height * scale) / 2 + framing.offset.y * targetSize.height

        return sourceTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Calculate the output size after applying the transform
    public static func transformedSize(_ size: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    public enum BuildError: Error, LocalizedError {
        case cannotCreateTrack
        case noVideoTrack
        case insertFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateTrack: return "Cannot create composition track"
            case .noVideoTrack: return "No video track in source"
            case .insertFailed(let msg): return "Insert failed: \(msg)"
            }
        }
    }
}
