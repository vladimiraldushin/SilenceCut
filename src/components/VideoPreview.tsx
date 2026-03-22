'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';

/**
 * Canvas Bridge approach: two hidden <video> elements render to one visible <canvas>.
 * While video A plays, video B pre-seeks to next fragment.
 * Canvas draws from active video — swap is invisible to user.
 * Uses requestVideoFrameCallback for frame-accurate rendering.
 */
export function VideoPreview() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const videoARef = useRef<HTMLVideoElement>(null);
  const videoBRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, setPlayheadPosition } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);

  // Playback state refs (avoid stale closures)
  const activeRef = useRef<'A' | 'B'>('A');
  const fragIndexRef = useRef(0);
  const includedRef = useRef<ReturnType<typeof useEditorStore.getState>['fragments']>([]);
  const rafRef = useRef<number>(0);

  const getVideo = (which: 'A' | 'B') => which === 'A' ? videoARef.current : videoBRef.current;

  // Set source duration
  useEffect(() => {
    const v = videoARef.current;
    if (!v) return;
    const handler = () => useEditorStore.setState({ sourceDuration: v.duration });
    v.addEventListener('loadedmetadata', handler);
    return () => v.removeEventListener('loadedmetadata', handler);
  }, [videoUrl]);

  // Draw active video frame to canvas
  const drawFrame = useCallback(() => {
    const canvas = canvasRef.current;
    const video = getVideo(activeRef.current);
    if (!canvas || !video || video.videoWidth === 0) return;

    // Resize canvas to match video
    if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
    }

    const ctx = canvas.getContext('2d');
    if (ctx) ctx.drawImage(video, 0, 0);
  }, []);

  // Pre-seek the inactive video to the next fragment
  const prebufferNext = useCallback(() => {
    const nextIdx = fragIndexRef.current + 1;
    const included = includedRef.current;
    if (nextIdx >= included.length) return;

    const inactiveKey = activeRef.current === 'A' ? 'B' : 'A';
    const inactive = getVideo(inactiveKey);
    if (!inactive) return;

    const next = included[nextIdx];
    inactive.currentTime = next.sourceStartTime;
  }, []);

  // Main render loop
  const renderLoop = useCallback(() => {
    const video = getVideo(activeRef.current);
    if (!video || video.paused) return;

    const t = video.currentTime;
    const included = includedRef.current;
    const fragIdx = fragIndexRef.current;
    const frag = included[fragIdx];

    if (!frag) {
      video.pause();
      setIsPlaying(false);
      setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
      return;
    }

    const fragEnd = frag.sourceStartTime + frag.sourceDuration;

    // Check if we've reached end of current fragment
    if (t >= fragEnd - 0.03) {
      const nextIdx = fragIdx + 1;
      if (nextIdx < included.length) {
        // SWAP: pause current, play next
        video.pause();

        const nextKey = activeRef.current === 'A' ? 'B' : 'A';
        const nextVideo = getVideo(nextKey);

        if (nextVideo) {
          // Ensure next video is at correct position
          const next = included[nextIdx];
          if (Math.abs(nextVideo.currentTime - next.sourceStartTime) > 0.5) {
            nextVideo.currentTime = next.sourceStartTime;
          }

          nextVideo.play();
          activeRef.current = nextKey;
          fragIndexRef.current = nextIdx;

          // Pre-seek the now-inactive video to next-next fragment
          setTimeout(prebufferNext, 50);
        }
      } else {
        // End of all fragments
        video.pause();
        setIsPlaying(false);
        setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
        return;
      }
    }

    // Draw current frame to canvas
    drawFrame();

    // Update playhead (edit time)
    let editTime = 0;
    for (let i = 0; i < fragIndexRef.current && i < included.length; i++) {
      editTime += included[i].sourceDuration;
    }
    const curFrag = included[fragIndexRef.current];
    if (curFrag) {
      const curVideo = getVideo(activeRef.current);
      if (curVideo) {
        editTime += Math.max(0, curVideo.currentTime - curFrag.sourceStartTime);
      }
    }
    setPlayheadPosition(editTime);

    rafRef.current = requestAnimationFrame(renderLoop);
  }, [drawFrame, prebufferNext, setPlayheadPosition]);

  // Toggle play/pause
  const togglePlay = useCallback(() => {
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);
    includedRef.current = included;

    if (isPlaying) {
      // Pause
      const video = getVideo(activeRef.current);
      video?.pause();
      setIsPlaying(false);
      cancelAnimationFrame(rafRef.current);
      return;
    }

    // Play
    const video = getVideo(activeRef.current);
    if (!video) return;

    if (included.length > 0) {
      // Find which fragment to start from
      const editTime = useEditorStore.getState().playheadPosition;
      let remaining = editTime;
      let fragIdx = 0;
      for (let i = 0; i < included.length; i++) {
        if (remaining <= included[i].sourceDuration + 0.01) {
          fragIdx = i;
          video.currentTime = included[i].sourceStartTime + remaining;
          break;
        }
        remaining -= included[i].sourceDuration;
      }
      fragIndexRef.current = fragIdx;
      activeRef.current = 'A';

      // Pre-buffer next fragment on video B
      prebufferNext();
    }

    video.play();
    setIsPlaying(true);
    rafRef.current = requestAnimationFrame(renderLoop);
  }, [isPlaying, renderLoop, prebufferNext]);

  // Draw initial frame when video loads or when paused and seeking
  useEffect(() => {
    const v = videoARef.current;
    if (!v) return;
    const handler = () => drawFrame();
    v.addEventListener('seeked', handler);
    v.addEventListener('loadeddata', handler);
    return () => {
      v.removeEventListener('seeked', handler);
      v.removeEventListener('loadeddata', handler);
    };
  }, [drawFrame, videoUrl]);

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
      {/* Visible canvas — user sees only this */}
      <canvas
        ref={canvasRef}
        className="max-h-full max-w-full rounded-lg bg-black"
        style={{ maxHeight: 'calc(100% - 50px)', objectFit: 'contain' }}
      />

      {/* Hidden video A */}
      <video ref={videoARef} src={videoUrl} preload="auto" playsInline muted={false}
        style={{ position: 'absolute', width: 1, height: 1, opacity: 0, pointerEvents: 'none' }} />

      {/* Hidden video B */}
      <video ref={videoBRef} src={videoUrl} preload="auto" playsInline muted
        style={{ position: 'absolute', width: 1, height: 1, opacity: 0, pointerEvents: 'none' }} />

      <button onClick={togglePlay} className="btn px-8 py-2 text-base">
        {isPlaying ? '⏸ Pause' : '▶ Play'}
      </button>
    </div>
  );
}
