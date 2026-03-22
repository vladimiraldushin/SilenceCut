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

  // SILENCE SKIP via timeupdate (fires ~4x/sec natively, reliable)
  const handleTimeUpdate = useCallback(() => {
    const video = videoRef.current;
    if (!video || video.paused) return;

    const sourceTime = video.currentTime;
    const fragments = useEditorStore.getState().fragments;
    const included = fragments.filter(f => f.isIncluded);

    if (included.length === 0) {
      setPlayheadPosition(sourceTime);
      return;
    }

    // Find current included fragment
    const current = included.find(
      f => sourceTime >= f.sourceStartTime && sourceTime < f.sourceStartTime + f.sourceDuration
    );

    if (current) {
      // In speech — update playhead
      let editTime = 0;
      for (const f of included) {
        if (f.id === current.id) {
          editTime += sourceTime - f.sourceStartTime;
          break;
        }
        editTime += f.sourceDuration;
      }
      setPlayheadPosition(editTime);
    } else {
      // In silence — skip to next speech
      const next = included.find(f => f.sourceStartTime > sourceTime);
      if (next) {
        video.currentTime = next.sourceStartTime;
      } else {
        video.pause();
        setIsPlaying(false);
        setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
      }
    }
  }, [setPlayheadPosition]);

  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      const fragments = useEditorStore.getState().fragments;
      const included = fragments.filter(f => f.isIncluded);

      if (included.length > 0) {
        const editTime = useEditorStore.getState().playheadPosition;
        let remaining = editTime;
        for (const f of included) {
          if (remaining <= f.sourceDuration) {
            video.currentTime = f.sourceStartTime + remaining;
            break;
          }
          remaining -= f.sourceDuration;
        }
      }

      video.play();
      setIsPlaying(true);
    } else {
      video.pause();
      setIsPlaying(false);
    }
  }, []);

  const handleEnded = useCallback(() => {
    setIsPlaying(false);
    setPlayheadPosition(0);
  }, [setPlayheadPosition]);

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
