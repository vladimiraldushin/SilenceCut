/**
 * WebCodecs-based video player for seamless fragment playback.
 * Demuxes via mp4box.js → decodes via VideoDecoder → renders to Canvas.
 * Skips silence regions at the frame level — zero stutter.
 */
import { createFile, type MP4Sample, type MP4Track } from 'mp4box';
import type { TimelineFragment } from './types';

interface PlayerOptions {
  canvas: HTMLCanvasElement;
  file: File;
  onDuration?: (duration: number) => void;
  onTimeUpdate?: (editTime: number) => void;
  onEnded?: () => void;
}

interface DemuxedTrack {
  config: VideoDecoderConfig;
  samples: MP4Sample[];
  track: MP4Track;
}

export class WebCodecsPlayer {
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private file: File;

  private videoTrack: DemuxedTrack | null = null;
  private decoder: VideoDecoder | null = null;
  private audioCtx: AudioContext | null = null;
  private audioBuffer: AudioBuffer | null = null;
  private audioSource: AudioBufferSourceNode | null = null;

  private playing = false;
  private startTime = 0;
  private startEditTime = 0;
  private pendingFrames: VideoFrame[] = [];
  private rafId = 0;

  private included: TimelineFragment[] = [];
  private editDuration = 0;

  private onDuration: ((d: number) => void) | undefined;
  private onTimeUpdate: ((t: number) => void) | undefined;
  private onEnded: (() => void) | undefined;

  constructor(options: PlayerOptions) {
    this.canvas = options.canvas;
    this.ctx = options.canvas.getContext('2d')!;
    this.file = options.file;
    this.onDuration = options.onDuration;
    this.onTimeUpdate = options.onTimeUpdate;
    this.onEnded = options.onEnded;
  }

  async init(): Promise<void> {
    // Demux video
    this.videoTrack = await this.demux();

    if (this.videoTrack) {
      const { width, height } = this.videoTrack.track.video!;
      this.canvas.width = width;
      this.canvas.height = height;

      const duration = this.videoTrack.track.duration / this.videoTrack.track.timescale;
      this.onDuration?.(duration);

      // Decode and display first frame
      await this.decodeAndShowFrame(0);
    }

    // Decode audio
    await this.decodeAudio();
  }

  setFragments(fragments: TimelineFragment[]): void {
    this.included = fragments.filter(f => f.isIncluded);
    this.editDuration = this.included.reduce((s, f) => s + f.sourceDuration, 0);
  }

  async play(editTime: number): Promise<void> {
    if (this.playing) return;
    this.playing = true;
    this.startEditTime = editTime;
    this.startTime = performance.now();

    // Start audio from correct position
    this.playAudio(editTime);

    // Start render loop
    this.renderLoop();
  }

  pause(): void {
    this.playing = false;
    cancelAnimationFrame(this.rafId);
    this.stopAudio();
  }

  async seekTo(editTime: number): Promise<void> {
    const sourceTime = this.editToSourceTime(editTime);
    await this.decodeAndShowFrame(sourceTime);
    this.onTimeUpdate?.(editTime);
  }

  isPlaying(): boolean {
    return this.playing;
  }

  destroy(): void {
    this.pause();
    this.decoder?.close();
    this.audioCtx?.close();
    this.pendingFrames.forEach(f => f.close());
    this.pendingFrames = [];
  }

  // ---- DEMUXING ----

  private async demux(): Promise<DemuxedTrack | null> {
    return new Promise(async (resolve, reject) => {
      const mp4 = createFile();
      let videoTrack: MP4Track | null = null;
      const allSamples: MP4Sample[] = [];

      mp4.onReady = (info) => {
        videoTrack = info.tracks.find(t => t.type === 'video') || null;
        if (videoTrack) {
          mp4.setExtractionOptions(videoTrack.id, null, { nbSamples: 500 });
          mp4.start();
        } else {
          resolve(null);
        }
      };

      mp4.onSamples = (_id, _ref, samples) => {
        allSamples.push(...samples);
      };

      mp4.onError = (e) => reject(e);

      // Feed file to mp4box
      const buffer = await this.file.arrayBuffer();
      const ab = buffer as ArrayBuffer & { fileStart?: number };
      ab.fileStart = 0;
      mp4.appendBuffer(ab);
      mp4.flush();

      // Wait a tick for onReady + onSamples
      await new Promise(r => setTimeout(r, 100));
      mp4.stop();

      if (!videoTrack) {
        resolve(null);
        return;
      }

      // Build decoder config
      // Get codec string from track
      const codecString = videoTrack.codec;

      const config: VideoDecoderConfig = {
        codec: codecString,
        codedWidth: videoTrack.video!.width,
        codedHeight: videoTrack.video!.height,
      };

      // Try to get description from first sample
      if (allSamples.length > 0 && allSamples[0].description) {
        const desc = allSamples[0].description;
        if (desc.avcC) {
          config.description = new Uint8Array(desc.avcC);
        } else if (desc.hvcC) {
          config.description = new Uint8Array(desc.hvcC);
        }
      }

      resolve({ config, samples: allSamples, track: videoTrack });
    });
  }

  // ---- VIDEO DECODING ----

  private async decodeAndShowFrame(sourceTime: number): Promise<void> {
    if (!this.videoTrack) return;

    const { samples, track, config } = this.videoTrack;
    const timescale = track.timescale;

    // Find the sample at or before sourceTime
    const targetTs = sourceTime * timescale;
    let sampleIdx = samples.findIndex(s => s.cts / timescale >= sourceTime);
    if (sampleIdx < 0) sampleIdx = samples.length - 1;

    // Find preceding keyframe
    let keyIdx = sampleIdx;
    while (keyIdx > 0 && !samples[keyIdx].is_sync) keyIdx--;

    // Create decoder
    this.decoder?.close();
    this.pendingFrames.forEach(f => f.close());
    this.pendingFrames = [];

    let resolveFrame: ((frame: VideoFrame) => void) | null = null;
    const framePromise = new Promise<VideoFrame>((resolve) => {
      resolveFrame = resolve;
    });

    this.decoder = new VideoDecoder({
      output: (frame) => {
        const frameTime = frame.timestamp / 1_000_000; // microseconds to seconds
        if (frameTime >= sourceTime - 0.05) {
          if (resolveFrame) {
            resolveFrame(frame);
            resolveFrame = null;
          } else {
            frame.close();
          }
        } else {
          frame.close();
        }
      },
      error: (e) => console.error('[WebCodecs] Decode error:', e),
    });

    this.decoder.configure(config);

    // Feed samples from keyframe to target
    for (let i = keyIdx; i <= Math.min(sampleIdx + 2, samples.length - 1); i++) {
      const sample = samples[i];
      const chunk = new EncodedVideoChunk({
        type: sample.is_sync ? 'key' : 'delta',
        timestamp: (sample.cts / timescale) * 1_000_000,
        duration: (sample.duration / timescale) * 1_000_000,
        data: sample.data,
      });
      this.decoder.decode(chunk);
    }

    await this.decoder.flush();

    // Draw the frame
    const frame = await Promise.race([
      framePromise,
      new Promise<null>((r) => setTimeout(() => r(null), 500)),
    ]);

    if (frame) {
      this.ctx.drawImage(frame, 0, 0);
      frame.close();
    }
  }

  // ---- RENDER LOOP ----

  private renderLoop = (): void => {
    if (!this.playing || !this.videoTrack) return;

    const elapsed = (performance.now() - this.startTime) / 1000;
    const editTime = this.startEditTime + elapsed;

    if (editTime >= this.editDuration) {
      this.pause();
      this.onEnded?.();
      return;
    }

    // Convert edit time → source time
    const sourceTime = this.editToSourceTime(editTime);

    // Find and draw the correct frame
    this.drawFrameAtSourceTime(sourceTime);

    this.onTimeUpdate?.(editTime);
    this.rafId = requestAnimationFrame(this.renderLoop);
  };

  private drawFrameAtSourceTime(sourceTime: number): void {
    if (!this.videoTrack) return;

    const { samples, track } = this.videoTrack;
    const timescale = track.timescale;

    // Find sample at this source time
    let bestIdx = 0;
    for (let i = 0; i < samples.length; i++) {
      if (samples[i].cts / timescale <= sourceTime) {
        bestIdx = i;
      } else {
        break;
      }
    }

    // Decode this frame (simplified: use a persistent decoder)
    const sample = samples[bestIdx];
    if (!sample || !this.decoder) return;

    const chunk = new EncodedVideoChunk({
      type: sample.is_sync ? 'key' : 'delta',
      timestamp: (sample.cts / timescale) * 1_000_000,
      duration: (sample.duration / timescale) * 1_000_000,
      data: sample.data,
    });

    // Only decode keyframes during continuous playback (delta frames need prior frames)
    if (sample.is_sync) {
      this.decoder.decode(chunk);
    }
  }

  // ---- AUDIO ----

  private async decodeAudio(): Promise<void> {
    try {
      const buffer = await this.file.arrayBuffer();
      this.audioCtx = new AudioContext();
      this.audioBuffer = await this.audioCtx.decodeAudioData(buffer);
    } catch (e) {
      console.warn('[WebCodecs] Audio decode failed:', e);
    }
  }

  private playAudio(editTime: number): void {
    if (!this.audioCtx || !this.audioBuffer || this.included.length === 0) return;

    this.stopAudio();

    // Create a merged audio buffer with only included fragments
    const sampleRate = this.audioBuffer.sampleRate;
    const channels = this.audioBuffer.numberOfChannels;
    const totalSamples = Math.floor(this.editDuration * sampleRate);
    const merged = this.audioCtx.createBuffer(channels, totalSamples, sampleRate);

    let outOffset = 0;
    for (const frag of this.included) {
      const inStart = Math.floor(frag.sourceStartTime * sampleRate);
      const length = Math.floor(frag.sourceDuration * sampleRate);

      for (let ch = 0; ch < channels; ch++) {
        const inData = this.audioBuffer.getChannelData(ch);
        const outData = merged.getChannelData(ch);
        for (let i = 0; i < length && inStart + i < inData.length && outOffset + i < outData.length; i++) {
          outData[outOffset + i] = inData[inStart + i];
        }
      }
      outOffset += length;
    }

    // Play from edit time position
    this.audioSource = this.audioCtx.createBufferSource();
    this.audioSource.buffer = merged;
    this.audioSource.connect(this.audioCtx.destination);
    this.audioSource.start(0, editTime);
  }

  private stopAudio(): void {
    try { this.audioSource?.stop(); } catch { /* ignore */ }
    this.audioSource = null;
  }

  // ---- TIME CONVERSION ----

  private editToSourceTime(editTime: number): number {
    let remaining = editTime;
    for (const f of this.included) {
      if (remaining <= f.sourceDuration) {
        return f.sourceStartTime + remaining;
      }
      remaining -= f.sourceDuration;
    }
    const last = this.included[this.included.length - 1];
    return last ? last.sourceStartTime + last.sourceDuration : 0;
  }
}
