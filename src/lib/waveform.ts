export interface WaveformData {
  peaks: Float32Array; // normalized 0-1
  duration: number;
  samplesPerSecond: number;
}

export async function generateWaveform(
  file: File,
  samplesPerSecond = 100
): Promise<WaveformData> {
  const arrayBuffer = await file.arrayBuffer();
  const audioCtx = new AudioContext({ sampleRate: 44100 });
  const audioBuffer = await audioCtx.decodeAudioData(arrayBuffer);
  audioCtx.close();

  const rawSamples = audioBuffer.getChannelData(0);
  const sampleRate = audioBuffer.sampleRate;
  const duration = audioBuffer.duration;
  const samplesPerPeak = Math.floor(sampleRate / samplesPerSecond);
  const totalPeaks = Math.floor(duration * samplesPerSecond);

  const peaks = new Float32Array(totalPeaks);

  for (let i = 0; i < totalPeaks; i++) {
    const start = i * samplesPerPeak;
    let max = 0;
    for (let j = start; j < start + samplesPerPeak && j < rawSamples.length; j++) {
      const abs = Math.abs(rawSamples[j]);
      if (abs > max) max = abs;
    }
    peaks[i] = max;
  }

  // Normalize
  let globalMax = 0;
  for (let i = 0; i < peaks.length; i++) {
    if (peaks[i] > globalMax) globalMax = peaks[i];
  }
  if (globalMax > 0) {
    for (let i = 0; i < peaks.length; i++) {
      peaks[i] /= globalMax;
    }
  }

  return { peaks, duration, samplesPerSecond };
}
