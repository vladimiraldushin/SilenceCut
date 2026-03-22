import { TimelineFragment, SilenceSettings, DetectionResult } from './types';

export async function detectSilence(
  file: File,
  settings: SilenceSettings,
  onProgress?: (progress: number) => void
): Promise<DetectionResult> {
  const startTime = performance.now();

  // 1. Decode audio
  const arrayBuffer = await file.arrayBuffer();
  const audioCtx = new AudioContext({ sampleRate: 44100 });
  const audioBuffer = await audioCtx.decodeAudioData(arrayBuffer);
  audioCtx.close();

  const samples = audioBuffer.getChannelData(0); // mono
  const sampleRate = audioBuffer.sampleRate;
  const chunkSize = 1024;
  const thresholdLinear = Math.pow(10, settings.thresholdDB / 20);

  // 2. Calculate RMS per chunk
  const totalChunks = Math.floor(samples.length / chunkSize);
  const levels: { time: number; isSilence: boolean }[] = [];

  for (let i = 0; i < totalChunks; i++) {
    const offset = i * chunkSize;
    let sumSq = 0;
    for (let j = 0; j < chunkSize; j++) {
      const s = samples[offset + j];
      sumSq += s * s;
    }
    const rms = Math.sqrt(sumSq / chunkSize);
    levels.push({
      time: offset / sampleRate,
      isSilence: rms < thresholdLinear,
    });

    if (onProgress && i % 100 === 0) {
      onProgress(i / totalChunks);
    }
  }

  onProgress?.(1);

  // 3. Build regions
  const chunkDuration = chunkSize / sampleRate;
  const audioDuration = samples.length / sampleRate;

  interface Region { start: number; end: number; isSilence: boolean; }
  const regions: Region[] = [];
  let regionStart = 0;
  let currentIsSilence = levels[0]?.isSilence ?? true;

  for (const level of levels) {
    if (level.isSilence !== currentIsSilence) {
      regions.push({ start: regionStart, end: level.time, isSilence: currentIsSilence });
      regionStart = level.time;
      currentIsSilence = level.isSilence;
    }
  }
  regions.push({ start: regionStart, end: audioDuration, isSilence: currentIsSilence });

  // 4. Build fragments with padding and min duration
  const paddingSec = settings.paddingMs / 1000;
  const fragments: TimelineFragment[] = [];
  let idCounter = 0;

  for (const region of regions) {
    const duration = region.end - region.start;

    if (region.isSilence && duration < settings.minDurationSec) {
      // Too short silence → treat as speech
      fragments.push({
        id: `f${idCounter++}`,
        sourceStartTime: region.start,
        sourceDuration: duration,
        type: 'speech',
        isIncluded: true,
      });
    } else if (region.isSilence) {
      const paddedStart = region.start + paddingSec;
      const paddedEnd = region.end - paddingSec;
      if (paddedEnd > paddedStart) {
        fragments.push({
          id: `f${idCounter++}`,
          sourceStartTime: paddedStart,
          sourceDuration: paddedEnd - paddedStart,
          type: 'silence',
          isIncluded: true,
        });
      }
    } else {
      fragments.push({
        id: `f${idCounter++}`,
        sourceStartTime: region.start,
        sourceDuration: duration,
        type: 'speech',
        isIncluded: true,
      });
    }
  }

  // 5. Merge consecutive same-type fragments
  const merged = mergeFragments(fragments);

  const silenceFragments = merged.filter(f => f.type === 'silence');
  return {
    fragments: merged,
    silenceCount: silenceFragments.length,
    silenceDuration: silenceFragments.reduce((sum, f) => sum + f.sourceDuration, 0),
    processingTimeMs: performance.now() - startTime,
  };
}

function mergeFragments(fragments: TimelineFragment[]): TimelineFragment[] {
  if (fragments.length === 0) return [];
  const result: TimelineFragment[] = [{ ...fragments[0] }];

  for (let i = 1; i < fragments.length; i++) {
    const prev = result[result.length - 1];
    const curr = fragments[i];
    if (prev.type === curr.type && prev.isIncluded === curr.isIncluded) {
      prev.sourceDuration = (curr.sourceStartTime + curr.sourceDuration) - prev.sourceStartTime;
    } else {
      result.push({ ...curr });
    }
  }
  return result;
}
