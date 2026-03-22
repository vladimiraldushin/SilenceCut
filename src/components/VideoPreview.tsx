'use client';

import { useRef, useEffect, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';
import { WebCodecsPlayer } from '@/lib/webcodecs-player';

/**
 * WebCodecs-based preview: demux → decode → canvas.
 * No <video> element seeking. Frames decoded directly, silence skipped at frame level.
 * Falls back to <video> element if WebCodecs not supported.
 */
export function VideoPreview() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const playerRef = useRef<WebCodecsPlayer | null>(null);
  const { videoUrl, file, setPlayheadPosition, fragments } = useEditorStore();
  const [isPlaying, setIsPlaying] = useState(false);
  const [useWebCodecs, setUseWebCodecs] = useState(true);
  const [status, setStatus] = useState('');

  // Check WebCodecs support
  useEffect(() => {
    if (typeof VideoDecoder === 'undefined') {
      setUseWebCodecs(false);
      console.log('[Preview] WebCodecs not supported, using <video> fallback');
    }
  }, []);

  // Initialize WebCodecs player when file changes
  useEffect(() => {
    if (!file || !canvasRef.current || !useWebCodecs) return;

    const canvas = canvasRef.current;
    setStatus('Loading...');

    const player = new WebCodecsPlayer({
      canvas,
      file,
      onDuration: (d) => {
        useEditorStore.setState({ sourceDuration: d });
        setStatus('');
      },
      onTimeUpdate: (t) => {
        setPlayheadPosition(t);
      },
      onEnded: () => {
        setIsPlaying(false);
        setPlayheadPosition(0);
      },
    });

    playerRef.current = player;
    player.init().catch((e) => {
      console.error('[Preview] WebCodecs init failed:', e);
      setUseWebCodecs(false);
      setStatus('WebCodecs failed, using fallback');
    });

    return () => {
      player.destroy();
      playerRef.current = null;
    };
  }, [file, useWebCodecs, setPlayheadPosition]);

  // Update player fragments when they change
  useEffect(() => {
    playerRef.current?.setFragments(fragments);
  }, [fragments]);

  // Toggle play/pause
  const togglePlay = useCallback(() => {
    const player = playerRef.current;

    if (useWebCodecs && player) {
      if (player.isPlaying()) {
        player.pause();
        setIsPlaying(false);
      } else {
        const editTime = useEditorStore.getState().playheadPosition;
        player.play(editTime);
        setIsPlaying(true);
      }
    } else {
      // Fallback: <video> element
      const video = videoRef.current;
      if (!video) return;
      if (video.paused) {
        video.play();
        setIsPlaying(true);
      } else {
        video.pause();
        setIsPlaying(false);
      }
    }
  }, [useWebCodecs]);

  // Click on canvas to seek (when paused)
  const handleCanvasClick = useCallback(() => {
    // Don't seek on click — use timeline for seeking
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

  // Fallback: <video> metadata
  const handleLoadedMetadata = useCallback(() => {
    if (videoRef.current && !useWebCodecs) {
      useEditorStore.setState({ sourceDuration: videoRef.current.duration });
    }
  }, [useWebCodecs]);

  if (!videoUrl) return null;

  return (
    <div className="flex flex-col items-center gap-3 w-full h-full p-2">
      {useWebCodecs ? (
        <canvas
          ref={canvasRef}
          onClick={handleCanvasClick}
          className="max-h-full max-w-full rounded-lg bg-black"
          style={{ maxHeight: 'calc(100% - 50px)', objectFit: 'contain' }}
        />
      ) : (
        <video
          ref={videoRef}
          src={videoUrl}
          onLoadedMetadata={handleLoadedMetadata}
          className="max-h-full max-w-full rounded-lg bg-black"
          style={{ maxHeight: 'calc(100% - 50px)' }}
          playsInline
        />
      )}

      {status && <span className="text-xs text-zinc-400">{status}</span>}

      <button onClick={togglePlay} className="btn px-8 py-2 text-base">
        {isPlaying ? '⏸ Pause' : '▶ Play'}
      </button>
    </div>
  );
}
