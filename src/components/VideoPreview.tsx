'use client';

import { useRef, useEffect, useCallback } from 'react';
import { useEditorStore } from '@/lib/store';

export function VideoPreview() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, fragments, playheadPosition, setPlayheadPosition, sourceDuration } = useEditorStore();
  const isPlayingRef = useRef(false);
  const animFrameRef = useRef<number>(0);

  // Set source duration when video metadata loads
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current) {
      useEditorStore.setState({ sourceDuration: videoRef.current.duration });
    }
  }, []);

  // Update playhead from video time during playback
  const updatePlayhead = useCallback(() => {
    if (!videoRef.current || !isPlayingRef.current) return;

    const video = videoRef.current;
    const sourceTime = video.currentTime;
    const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);

    if (included.length === 0) {
      setPlayheadPosition(sourceTime);
    } else {
      // Check if we're in an excluded region
      const inIncluded = included.some(
        f => sourceTime >= f.sourceStartTime && sourceTime < f.sourceStartTime + f.sourceDuration
      );

      if (!inIncluded) {
        // Skip to next included fragment
        const next = included.find(f => f.sourceStartTime > sourceTime);
        if (next) {
          video.currentTime = next.sourceStartTime;
        } else {
          video.pause();
          isPlayingRef.current = false;
          return;
        }
      }

      // Convert source time to edit time
      let editTime = 0;
      for (const f of included) {
        if (sourceTime >= f.sourceStartTime && sourceTime < f.sourceStartTime + f.sourceDuration) {
          editTime += sourceTime - f.sourceStartTime;
          break;
        } else if (sourceTime >= f.sourceStartTime + f.sourceDuration) {
          editTime += f.sourceDuration;
        }
      }
      setPlayheadPosition(editTime);
    }

    animFrameRef.current = requestAnimationFrame(updatePlayhead);
  }, [setPlayheadPosition]);

  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      // Seek to correct source position before playing
      const included = useEditorStore.getState().fragments.filter(f => f.isIncluded);
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
      isPlayingRef.current = true;
      animFrameRef.current = requestAnimationFrame(updatePlayhead);
    } else {
      video.pause();
      isPlayingRef.current = false;
      cancelAnimationFrame(animFrameRef.current);
    }
  }, [updatePlayhead]);

  // Keyboard shortcut: Space to play/pause
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.code === 'Space' && !e.target?.toString().includes('Input')) {
        e.preventDefault();
        togglePlay();
      }
      if (e.metaKey && e.key === 'z') {
        e.preventDefault();
        if (e.shiftKey) useEditorStore.getState().redo();
        else useEditorStore.getState().undo();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [togglePlay]);

  // Cleanup
  useEffect(() => {
    return () => cancelAnimationFrame(animFrameRef.current);
  }, []);

  if (!videoUrl) return null;

  return (
    <div className="flex flex-col items-center gap-2 w-full h-full">
      <video
        ref={videoRef}
        src={videoUrl}
        onLoadedMetadata={handleLoadedMetadata}
        className="max-h-full max-w-full rounded-lg"
        style={{ aspectRatio: '9/16', maxHeight: '100%' }}
      />
      <button onClick={togglePlay} className="btn px-6">
        ▶ Play / Pause
      </button>
    </div>
  );
}
