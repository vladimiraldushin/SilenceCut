'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';

export function VideoPreview() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, setPlayheadPosition } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);

  // Set source duration when video metadata loads
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current) {
      useEditorStore.setState({ sourceDuration: videoRef.current.duration });
    }
  }, []);

  const skipDataRef = useRef<{ ends: number[]; starts: number[] }>({ ends: [], starts: [] });
  const rafRef = useRef<number>(0);

  // Build skip map when fragments change
  const buildSkipMap = useCallback(() => {
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);
    const ends: number[] = [];
    const starts: number[] = [];
    for (let i = 0; i < included.length - 1; i++) {
      ends.push(included[i].sourceStartTime + included[i].sourceDuration);
      starts.push(included[i + 1].sourceStartTime);
    }
    skipDataRef.current = { ends, starts };
  }, []);

  // Playback monitor — runs via RAF for smooth skip detection
  const playbackMonitor = useCallback(() => {
    const video = videoRef.current;
    if (!video || video.paused) return;

    const t = video.currentTime;
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);

    if (included.length === 0) {
      setPlayheadPosition(t);
      rafRef.current = requestAnimationFrame(playbackMonitor);
      return;
    }

    // Check if approaching end of current fragment — pre-seek 100ms early
    const { ends, starts } = skipDataRef.current;
    for (let i = 0; i < ends.length; i++) {
      const distToEnd = ends[i] - t;
      if (distToEnd > 0 && distToEnd < 0.15) {
        // About to hit silence — skip NOW using fastSeek
        if (video.fastSeek) {
          video.fastSeek(starts[i]);
        } else {
          video.currentTime = starts[i];
        }
        break;
      }
    }

    // Check if already in silence (missed pre-seek)
    const inIncluded = included.some(
      f => t >= f.sourceStartTime && t < f.sourceStartTime + f.sourceDuration
    );
    if (!inIncluded) {
      const next = included.find(f => f.sourceStartTime > t);
      if (next) {
        if (video.fastSeek) video.fastSeek(next.sourceStartTime);
        else video.currentTime = next.sourceStartTime;
      } else {
        video.pause();
        setIsPlaying(false);
        setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
        return;
      }
    }

    // Update playhead (throttled — only every 3rd frame)
    if (Math.random() < 0.33) {
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
    }

    rafRef.current = requestAnimationFrame(playbackMonitor);
  }, [setPlayheadPosition]);

  // timeupdate as backup (less frequent, for when RAF stops)
  const handleTimeUpdate = useCallback(() => {
    // Only used for basic position update, skip logic is in RAF
    const video = videoRef.current;
    if (!video || video.paused) return;
    // Trigger redraw of playhead in timeline
    const t = video.currentTime;
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);
    if (included.length === 0) {
      setPlayheadPosition(t);
    }
  }, [setPlayheadPosition]);

  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);

      if (included.length > 0) {
        // Seek to correct source position
        const editTime = useEditorStore.getState().playheadPosition;
        let remaining = editTime;
        for (const f of included) {
          if (remaining <= f.sourceDuration) {
            video.currentTime = f.sourceStartTime + remaining;
            break;
          }
          remaining -= f.sourceDuration;
        }
        // Build skip map for fast lookups
        buildSkipMap();
      }

      video.play();
      setIsPlaying(true);
      // Start RAF monitor for smooth silence skipping
      rafRef.current = requestAnimationFrame(playbackMonitor);
    } else {
      video.pause();
      setIsPlaying(false);
      cancelAnimationFrame(rafRef.current);
    }
  }, [playbackMonitor, buildSkipMap]);

  const handleEnded = useCallback(() => {
    setIsPlaying(false);
    cancelAnimationFrame(rafRef.current);
    setPlayheadPosition(0);
  }, [setPlayheadPosition]);

  // Cleanup RAF on unmount
  useEffect(() => {
    return () => cancelAnimationFrame(rafRef.current);
  }, []);

  // Keyboard: Space = play/pause, Cmd+Z = undo
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA') return;

      if (e.code === 'Space') {
        e.preventDefault();
        togglePlay();
      }
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
        onTimeUpdate={handleTimeUpdate}
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
