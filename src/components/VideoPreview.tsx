'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';

/**
 * Dual-video preview: two <video> elements swap at fragment transitions.
 * While video A plays current fragment, video B pre-seeks to next fragment.
 * At transition: swap (B becomes visible, A pre-seeks to next-next).
 * Result: zero stutter between fragments.
 */
export function VideoPreview() {
  const videoARef = useRef<HTMLVideoElement>(null);
  const videoBRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, setPlayheadPosition } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);
  const [activeVideo, setActiveVideo] = useState<'A' | 'B'>('A');
  const rafRef = useRef<number>(0);
  const currentFragIndexRef = useRef(0);

  const getActive = () => activeVideo === 'A' ? videoARef.current : videoBRef.current;
  const getInactive = () => activeVideo === 'A' ? videoBRef.current : videoARef.current;

  // Set source duration
  const handleLoadedMetadata = useCallback(() => {
    const v = videoARef.current;
    if (v) useEditorStore.setState({ sourceDuration: v.duration });
  }, []);

  // Pre-buffer the next fragment on the inactive video
  const prebufferNext = useCallback((fragIndex: number) => {
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);
    const nextIdx = fragIndex + 1;
    if (nextIdx >= included.length) return;

    const inactive = getInactive();
    if (!inactive) return;

    const next = included[nextIdx];
    inactive.currentTime = next.sourceStartTime;
    // Browser will start buffering from this position
  }, [activeVideo]);

  // Playback monitor — check if we need to swap videos
  const monitor = useCallback(() => {
    const active = getActive();
    if (!active || active.paused) return;

    const t = active.currentTime;
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);
    const fragIdx = currentFragIndexRef.current;

    if (included.length === 0) {
      setPlayheadPosition(t);
      rafRef.current = requestAnimationFrame(monitor);
      return;
    }

    const currentFrag = included[fragIdx];
    if (!currentFrag) {
      // Past all fragments — stop
      active.pause();
      setIsPlaying(false);
      setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
      return;
    }

    const fragEnd = currentFrag.sourceStartTime + currentFrag.sourceDuration;

    // Check if approaching end of current fragment
    if (t >= fragEnd - 0.05) {
      // SWAP to next fragment
      const nextIdx = fragIdx + 1;
      if (nextIdx < included.length) {
        const inactive = getInactive();
        if (inactive) {
          // Start playing the pre-buffered inactive video
          active.pause();
          inactive.play();
          currentFragIndexRef.current = nextIdx;
          setActiveVideo(prev => prev === 'A' ? 'B' : 'A');

          // Pre-buffer the NEXT-next fragment on the now-inactive video
          setTimeout(() => prebufferNext(nextIdx), 100);
        }
      } else {
        // Last fragment — stop
        active.pause();
        setIsPlaying(false);
        setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
        return;
      }
    }

    // Update playhead position (edit time)
    let editTime = 0;
    for (let i = 0; i < fragIdx; i++) {
      editTime += included[i].sourceDuration;
    }
    if (currentFrag) {
      editTime += Math.max(0, t - currentFrag.sourceStartTime);
    }
    setPlayheadPosition(editTime);

    rafRef.current = requestAnimationFrame(monitor);
  }, [activeVideo, setPlayheadPosition, prebufferNext]);

  // Toggle play/pause
  const togglePlay = useCallback(() => {
    const active = getActive();
    if (!active) return;

    if (active.paused) {
      const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);

      if (included.length > 0) {
        // Find which fragment corresponds to current playhead
        const editTime = useEditorStore.getState().playheadPosition;
        let remaining = editTime;
        let fragIdx = 0;
        for (let i = 0; i < included.length; i++) {
          if (remaining <= included[i].sourceDuration) {
            fragIdx = i;
            active.currentTime = included[i].sourceStartTime + remaining;
            break;
          }
          remaining -= included[i].sourceDuration;
        }
        currentFragIndexRef.current = fragIdx;

        // Pre-buffer next fragment
        prebufferNext(fragIdx);
      }

      active.play();
      setIsPlaying(true);
      rafRef.current = requestAnimationFrame(monitor);
    } else {
      active.pause();
      setIsPlaying(false);
      cancelAnimationFrame(rafRef.current);
    }
  }, [monitor, prebufferNext, activeVideo]);

  // Handle video end
  const handleEnded = useCallback(() => {
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
      <div className="relative max-h-full max-w-full" style={{ maxHeight: 'calc(100% - 50px)' }}>
        {/* Video A */}
        <video
          ref={videoARef}
          src={videoUrl}
          onLoadedMetadata={handleLoadedMetadata}
          onEnded={handleEnded}
          className="rounded-lg bg-black"
          style={{
            maxHeight: '100%',
            maxWidth: '100%',
            display: activeVideo === 'A' ? 'block' : 'none',
          }}
          playsInline
          preload="auto"
        />
        {/* Video B */}
        <video
          ref={videoBRef}
          src={videoUrl}
          onEnded={handleEnded}
          className="rounded-lg bg-black"
          style={{
            maxHeight: '100%',
            maxWidth: '100%',
            display: activeVideo === 'B' ? 'block' : 'none',
          }}
          playsInline
          preload="auto"
        />
      </div>
      <button onClick={togglePlay} className="btn px-8 py-2 text-base">
        {isPlaying ? '⏸ Pause' : '▶ Play'}
      </button>
    </div>
  );
}
