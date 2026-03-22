'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';

/**
 * Video preview with silence-skipping playback.
 * Uses native <video> element + onTimeUpdate for silence skip.
 * After "Remove All Silence", auto-generates preview via FFmpeg for smooth playback.
 */
export function VideoPreview() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { videoUrl, file, setPlayheadPosition, fragments } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [isGenerating, setIsGenerating] = useState(false);

  // Determine if we should show preview version
  const hasRemovedSilence = fragments.some(f => f.type === 'silence' && !f.isIncluded);
  const included = fragments.filter(f => f.isIncluded);

  // Set source duration
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current && !previewUrl) {
      useEditorStore.setState({ sourceDuration: videoRef.current.duration });
    }
  }, [previewUrl]);

  // Silence skip during playback (only when playing original, not preview)
  const handleTimeUpdate = useCallback(() => {
    const video = videoRef.current;
    if (!video || video.paused || previewUrl) return;

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

  // Preview playback: update playhead linearly
  const handlePreviewTimeUpdate = useCallback(() => {
    const video = videoRef.current;
    if (!video || video.paused || !previewUrl) return;
    setPlayheadPosition(video.currentTime);
  }, [previewUrl, setPlayheadPosition]);

  // Auto-generate preview when silence is removed
  useEffect(() => {
    if (!hasRemovedSilence || !file || included.length === 0) {
      // Clear preview if silence restored
      if (previewUrl && !hasRemovedSilence) {
        URL.revokeObjectURL(previewUrl);
        setPreviewUrl(null);
      }
      return;
    }

    // Generate preview via FFmpeg
    let cancelled = false;
    setIsGenerating(true);

    (async () => {
      try {
        const formData = new FormData();
        formData.append('video', file);
        formData.append('fragments', JSON.stringify(fragments));

        const res = await fetch('/api/export', { method: 'POST', body: formData });
        if (!res.ok) throw new Error('Export failed');

        const blob = await res.blob();
        if (cancelled) return;

        const url = URL.createObjectURL(blob);
        setPreviewUrl(url);
        console.log('[Preview] Generated smooth preview');
      } catch (e) {
        console.error('[Preview] Auto-preview failed:', e);
        // Fallback: continue with skip-based playback
      }
      if (!cancelled) setIsGenerating(false);
    })();

    return () => { cancelled = true; };
  // Only regenerate when fragments actually change
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hasRemovedSilence, file, JSON.stringify(included.map(f => f.id))]);

  // Toggle play/pause
  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;

    if (video.paused) {
      if (!previewUrl && included.length > 0) {
        // Playing original with silence skip — seek to correct position
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
    return () => {
      if (previewUrl) URL.revokeObjectURL(previewUrl);
    };
  }, [previewUrl]);

  if (!videoUrl) return null;

  const displayUrl = previewUrl || videoUrl;

  return (
    <div className="flex flex-col items-center gap-3 w-full h-full p-2">
      <video
        ref={videoRef}
        src={displayUrl}
        onLoadedMetadata={handleLoadedMetadata}
        onTimeUpdate={previewUrl ? handlePreviewTimeUpdate : handleTimeUpdate}
        onEnded={handleEnded}
        className="max-h-full max-w-full rounded-lg bg-black"
        style={{ maxHeight: 'calc(100% - 50px)' }}
        playsInline
      />

      <div className="flex items-center gap-3">
        <button onClick={togglePlay} className="btn px-8 py-2 text-base">
          {isPlaying ? '⏸ Pause' : '▶ Play'}
        </button>
        {isGenerating && (
          <span className="text-xs text-blue-400 animate-pulse">Generating preview...</span>
        )}
        {previewUrl && !isGenerating && (
          <span className="text-xs text-green-400">Smooth preview</span>
        )}
      </div>
    </div>
  );
}
