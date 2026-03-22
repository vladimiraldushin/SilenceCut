import Foundation
import AVFoundation
import Accelerate

/// High-performance silence detection engine using vDSP
actor SilenceDetector {

    enum DetectionError: Error, LocalizedError {
        case noAudioTrack
        case cannotCreateReader
        case cancelled
        case processingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "No audio track found in the video"
            case .cannotCreateReader: return "Cannot read audio data"
            case .cancelled: return "Detection was cancelled"
            case .processingFailed(let msg): return "Processing failed: \(msg)"
            }
        }
    }

    struct AnalysisResult {
        let fragments: [TimelineFragment]
        let audioDuration: Double
        let silenceCount: Int
        let silenceDuration: Double
        let processingTime: Double
    }

    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    /// Detect silence in the audio track of the given asset
    func detectSilence(
        in asset: AVAsset,
        settings: SilenceDetectionSettings,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AnalysisResult {
        isCancelled = false
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Get audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DetectionError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let audioDuration = CMTimeGetSeconds(duration)

        // 2. Configure asset reader for PCM output
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DetectionError.cannotCreateReader
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw DetectionError.processingFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        // 3. Process audio in chunks, calculate RMS power
        let sampleRate: Double = 44100
        let chunkSize = 1024  // samples per analysis chunk
        let thresholdLinear = powf(10.0, settings.thresholdDB / 20.0)

        var powerLevels: [(time: Double, rms: Float)] = []
        var sampleIndex: Int64 = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if isCancelled {
                reader.cancelReading()
                throw DetectionError.cancelled
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
            }

            let floatCount = length / MemoryLayout<Float>.size

            data.withUnsafeBytes { rawBuffer in
                guard let floatPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }

                var offset = 0
                while offset + chunkSize <= floatCount {
                    var rms: Float = 0
                    vDSP_rmsqv(floatPointer.advanced(by: offset), 1, &rms, vDSP_Length(chunkSize))

                    let time = Double(sampleIndex + Int64(offset)) / sampleRate
                    powerLevels.append((time: time, rms: rms))

                    offset += chunkSize
                }
            }

            sampleIndex += Int64(floatCount)

            // Report progress
            let progress = Double(sampleIndex) / (audioDuration * sampleRate)
            progressHandler?(min(progress, 1.0))
        }

        // 4. Classify chunks as speech/silence
        _ = Double(chunkSize) / sampleRate

        var regions: [(start: Double, end: Double, isSilence: Bool)] = []
        var currentStart = 0.0
        var currentIsSilence = powerLevels.first.map { $0.rms < thresholdLinear } ?? true

        for level in powerLevels {
            let isSilence = level.rms < thresholdLinear
            if isSilence != currentIsSilence {
                regions.append((start: currentStart, end: level.time, isSilence: currentIsSilence))
                currentStart = level.time
                currentIsSilence = isSilence
            }
        }
        // Add the last region
        regions.append((start: currentStart, end: audioDuration, isSilence: currentIsSilence))

        // 5. Filter by minimum duration and apply padding
        var fragments: [TimelineFragment] = []

        for region in regions {
            let duration = region.end - region.start

            if region.isSilence && duration < settings.minDurationSec {
                // Too short silence — treat as speech
                fragments.append(TimelineFragment(
                    sourceStartTime: region.start,
                    sourceDuration: duration,
                    type: .speech,
                    isIncluded: true
                ))
            } else if region.isSilence {
                // Apply padding: shrink silence, expand neighboring speech
                let paddedStart = region.start + settings.paddingSec
                let paddedEnd = region.end - settings.paddingSec
                let paddedDuration = paddedEnd - paddedStart

                if paddedDuration > 0 {
                    fragments.append(TimelineFragment(
                        sourceStartTime: paddedStart,
                        sourceDuration: paddedDuration,
                        type: .silence,
                        isIncluded: true  // included initially, user removes via "Remove All"
                    ))
                }
            } else {
                fragments.append(TimelineFragment(
                    sourceStartTime: region.start,
                    sourceDuration: duration,
                    type: .speech,
                    isIncluded: true
                ))
            }
        }

        // 6. Merge consecutive same-type fragments
        fragments = mergeConsecutiveFragments(fragments)

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        let silenceFragments = fragments.filter { $0.type == .silence }

        return AnalysisResult(
            fragments: fragments,
            audioDuration: audioDuration,
            silenceCount: silenceFragments.count,
            silenceDuration: silenceFragments.reduce(0) { $0 + $1.sourceDuration },
            processingTime: processingTime
        )
    }

    /// Merge consecutive fragments of the same type
    private func mergeConsecutiveFragments(_ fragments: [TimelineFragment]) -> [TimelineFragment] {
        guard !fragments.isEmpty else { return [] }

        var merged: [TimelineFragment] = []
        var current = fragments[0]

        for i in 1..<fragments.count {
            let next = fragments[i]
            if current.type == next.type && current.isIncluded == next.isIncluded {
                // Merge
                current = TimelineFragment(
                    sourceStartTime: current.sourceStartTime,
                    sourceDuration: next.sourceEndTime - current.sourceStartTime,
                    type: current.type,
                    isIncluded: current.isIncluded
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        return merged
    }
}
