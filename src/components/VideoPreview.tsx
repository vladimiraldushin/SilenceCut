'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';

const FAST_RATE = 16; // speed during silence (16x = 1 sec silence plays in 62ms)

/**
 * Continuous playback — video element NEVER seeks.
 * Speech: play at 1x, audio ON.
 * Silence: play at 16x, audio OFF (flies through in milliseconds).
 * Zero seeks = zero stutter.
 */
export function VideoPreview() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, setPlayheadPosition, fragments } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);
  const rafRef = useRef<number>(0);

  const included = fragments.filter(f => f.isIncluded);
  const excluded = fragments.filter(f => !f.isIncluded);

  // Set source duration
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current) {
      useEditorStore.setState({ sourceDuration: videoRef.current.duration });
    }
  }, []);

  // Playback monitor: adjust speed + mute based on current position
  const monitor = useCallback(() => {
    const video = videoRef.current;
    if (!video || video.paused) return;

    const t = video.currentTime;

    // Check if we're in a silence region
    const inSilence = excluded.some(
      f => t >= f.sourceStartTime && t < f.sourceStartTime + f.sourceDuration
    );

    if (inSilence) {
      // SILENCE: speed up, mute
      if (video.playbackRate !== FAST_RATE) {
        video.playbackRate = FAST_RATE;
        video.muted = true;
      }
    } else {
      // SPEECH: normal speed, unmute
      if (video.playbackRate !== 1) {
        video.playbackRate = 1;
        video.muted = false;
      }

      // Update playhead (edit time = only speech time elapsed)
      if (included.length > 0) {
        let editTime = 0;
        for (const f of included) {
          const end = f.sourceStartTime + f.sourceDuration;
          if (t >= f.sourceStartTime && t < end) {
            editTime += t - f.sourceStartTime;
            break;
          } else if (t >= end) {
            editTime += f.sourceDuration;
          }
        }
        setPlayheadPosition(editTime);
      } else {
        setPlayheadPosition(t);
      }
    }

    // Check if past all content
    const lastIncluded = included[included.length - 1];
    if (lastIncluded && t >= lastIncluded.sourceStartTime + lastIncluded.sourceDuration + 0.1) {
      // Check if there's more content after
      const hasMoreSpeech = included.some(f => f.sourceStartTime > t);
      if (!hasMoreSpeech) {
        video.pause();
        video.playbackRate = 1;
        video.muted = false;
        setIsPlaying(false);
        setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
        return;
      }
    }

    rafRef.current = requestAnimationFrame(monitor);
  }, [included, excluded, setPlayheadPosition]);

  // Toggle play/pause
  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      if (included.length > 0) {
        // Seek to correct source position (only on initial play)
        const editTime = useEditorStore.getState().playheadPosition;
        let remaining = editTime;
        for (const f of included) {
          if (remaining <= f.sourceDuration + 0.01) {
            video.currentTime = f.sourceStartTime + remaining;
            break;
          }
          remaining -= f.sourceDuration;
        }
      }
      video.playbackRate = 1;
      video.muted = false;
      video.play();
      setIsPlaying(true);
      rafRef.current = requestAnimationFrame(monitor);
    } else {
      video.pause();
      video.playbackRate = 1;
      video.muted = false;
      setIsPlaying(false);
      cancelAnimationFrame(rafRef.current);
    }
  }, [included, monitor]);

  const handleEnded = useCallback(() => {
    const video = videoRef.current;
    if (video) {
      video.playbackRate = 1;
      video.muted = false;
    }
    setIsPlaying(false);
    cancelAnimationFrame(rafRef.current);
    setPlayheadPosition(0);
  }, [setPlayheadPosition]);

  // Cleanup
  useEffect(() => {
    return () => cancelAnimationFrame(rafRef.current);
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA') return;
      if (e.code === 'Space') { e.preventDefault(); togglePlay(); }
      if ((e.metaKey || e.ctrlKey) && e.key === 'z') {
        e.preventDefault();
        if (e.shiftKey) useEditorStore.getState().redo();
        else useEditorStore.getState().undo();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [togglePlay]);

  if (!videoUrl) return null;

  return (
    <div className="flex flex-col items-center gap-3 w-full h-full p-2">
      <video
        ref={videoRef}
        src={videoUrl}
        onLoadedMetadata={handleLoadedMetadata}
        onEnded={handleEnded}
        className="max-h-full max-w-full rounded-lg bg-black"
        style={{ maxHeight: 'calc(100% - 50px)' }}
        playsInline
      />
      <button onClick={togglePlay} className="btn px-8 py-2 text-base">
        {isPlaying ? '⏸ Pause' : '▶ Play'}
      </button>
    </div>
  );
}
