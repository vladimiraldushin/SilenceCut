'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';

/**
 * Two playback modes:
 * 1. Edit mode: <video> + silence-skip (some stutter, instant response)
 * 2. Preview mode: plays FFmpeg-generated file (smooth, requires build)
 *
 * User edits freely, clicks "Build Preview" when ready to watch smooth.
 */
export function VideoPreview() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, file, setPlayheadPosition, fragments } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [building, setBuilding] = useState(false);

  const included = fragments.filter(f => f.isIncluded);
  const hasEdits = fragments.some(f => f.type === 'silence' && !f.isIncluded);

  // Invalidate preview when fragments change
  useEffect(() => {
    if (previewUrl) {
      URL.revokeObjectURL(previewUrl);
      setPreviewUrl(null);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fragments]);

  // Set source duration
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current && !previewUrl) {
      useEditorStore.setState({ sourceDuration: videoRef.current.duration });
    }
  }, [previewUrl]);

  // Silence skip (edit mode only — when no preview)
  const handleTimeUpdate = useCallback(() => {
    const video = videoRef.current;
    if (!video || video.paused) return;

    if (previewUrl) {
      // Preview mode — just update playhead linearly
      setPlayheadPosition(video.currentTime);
      return;
    }

    const t = video.currentTime;
    if (included.length === 0) {
      setPlayheadPosition(t);
      return;
    }

    const current = included.find(
      f => t >= f.sourceStartTime && t < f.sourceStartTime + f.sourceDuration
    );

    if (current) {
      let editTime = 0;
      for (const f of included) {
        if (f.id === current.id) {
          editTime += t - f.sourceStartTime;
          break;
        }
        editTime += f.sourceDuration;
      }
      setPlayheadPosition(editTime);
    } else {
      const next = included.find(f => f.sourceStartTime > t);
      if (next) {
        video.currentTime = next.sourceStartTime;
      } else {
        video.pause();
        setIsPlaying(false);
        setPlayheadPosition(included.reduce((s, f) => s + f.sourceDuration, 0));
      }
    }
  }, [included, previewUrl, setPlayheadPosition]);

  // Build Preview via FFmpeg
  const buildPreview = useCallback(async () => {
    if (!file || included.length === 0) return;
    setBuilding(true);

    try {
      const formData = new FormData();
      formData.append('video', file);
      formData.append('fragments', JSON.stringify(fragments));

      const res = await fetch('/api/export', { method: 'POST', body: formData });
      if (!res.ok) throw new Error('Failed');

      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      setPreviewUrl(url);

      // Switch video to preview
      if (videoRef.current) {
        videoRef.current.src = url;
        videoRef.current.load();
      }
    } catch (e) {
      console.error('[Preview] Build failed:', e);
    }

    setBuilding(false);
  }, [file, fragments, included]);

  // Switch back to original
  const clearPreview = useCallback(() => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    setPreviewUrl(null);
    if (videoRef.current && videoUrl) {
      videoRef.current.src = videoUrl;
      videoRef.current.load();
    }
  }, [previewUrl, videoUrl]);

  // Toggle play/pause
  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      if (!previewUrl && included.length > 0) {
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
      video.play();
      setIsPlaying(true);
    } else {
      video.pause();
      setIsPlaying(false);
    }
  }, [included, previewUrl]);

  const handleEnded = useCallback(() => {
    setIsPlaying(false);
    setPlayheadPosition(0);
  }, [setPlayheadPosition]);

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

  // Cleanup
  useEffect(() => {
    return () => { if (previewUrl) URL.revokeObjectURL(previewUrl); };
  }, [previewUrl]);

  if (!videoUrl) return null;

  return (
    <div className="flex flex-col items-center gap-3 w-full h-full p-2">
      <video
        ref={videoRef}
        src={previewUrl || videoUrl}
        onLoadedMetadata={handleLoadedMetadata}
        onTimeUpdate={handleTimeUpdate}
        onEnded={handleEnded}
        className="max-h-full max-w-full rounded-lg bg-black"
        style={{ maxHeight: 'calc(100% - 60px)' }}
        playsInline
      />

      <div className="flex items-center gap-2 flex-wrap justify-center">
        <button onClick={togglePlay} className="btn px-6 py-2">
          {isPlaying ? '⏸ Pause' : '▶ Play'}
        </button>

        {hasEdits && !previewUrl && (
          <button onClick={buildPreview} disabled={building} className="btn btn-primary px-4 py-2">
            {building ? '⏳ Building...' : '🎬 Build Preview'}
          </button>
        )}

        {previewUrl && (
          <>
            <span className="text-xs text-green-400">✓ Smooth preview</span>
            <button onClick={clearPreview} className="btn px-3 py-1 text-xs">
              Back to edit
            </button>
          </>
        )}
      </div>
    </div>
  );
}
