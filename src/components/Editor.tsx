'use client';

import { useRef, useCallback, useState } from 'react';
import { useEditorStore } from '@/lib/store';
import { detectSilence } from '@/lib/silence-detector';
import { generateWaveform } from '@/lib/waveform';
import { VideoPreview } from './VideoPreview';
import { Timeline } from './Timeline';
import { SilencePanel } from './SilencePanel';
import { FragmentList } from './FragmentList';
import { PRESETS } from '@/lib/types';

export function Editor() {
  const store = useEditorStore();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [isDetecting, setIsDetecting] = useState(false);
  const [progress, setProgress] = useState(0);
  const [status, setStatus] = useState('');

  const handleFileSelect = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      store.setFile(file);
      setStatus(`Loaded: ${file.name}`);
    }
  }, [store]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (file && file.type.startsWith('video/')) {
      store.setFile(file);
      setStatus(`Loaded: ${file.name}`);
    }
  }, [store]);

  const handleDetect = useCallback(async () => {
    if (!store.file) return;
    setIsDetecting(true);
    setProgress(0);
    setStatus('Detecting silence...');

    try {
      const result = await detectSilence(store.file, store.silenceSettings, setProgress);
      store.setFragments(result.fragments);

      const waveform = await generateWaveform(store.file);
      store.setWaveformData(waveform);

      setStatus(`${result.fragments.length} fragments (${result.silenceCount} silence, ${(result.processingTimeMs / 1000).toFixed(1)}s)`);
    } catch (err) {
      setStatus(`Error: ${err instanceof Error ? err.message : 'Unknown'}`);
    }

    setIsDetecting(false);
  }, [store]);

  const formatTime = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

  return (
    <div
      className="flex flex-col h-screen"
      onDragOver={e => e.preventDefault()}
      onDrop={handleDrop}
    >
      {/* Toolbar */}
      <div className="flex items-center gap-3 px-4 py-2 bg-zinc-900 border-b border-zinc-800">
        <input type="file" ref={fileInputRef} accept="video/*" onChange={handleFileSelect} className="hidden" />
        <button onClick={() => fileInputRef.current?.click()} className="btn">
          Import
        </button>
        <button onClick={handleDetect} disabled={!store.file || isDetecting} className="btn btn-primary">
          {isDetecting ? `Detecting ${Math.round(progress * 100)}%` : 'Detect Silence'}
        </button>
        <button onClick={() => store.undo()} disabled={store.undoStack.length === 0} className="btn">
          Undo
        </button>
        <button onClick={() => store.redo()} disabled={store.redoStack.length === 0} className="btn">
          Redo
        </button>

        {status && <span className="text-xs text-zinc-400 ml-2">{status}</span>}

        <div className="flex-1" />

        {store.silenceDetected && (
          <div className="text-xs text-right">
            <div className="text-green-400">Saved: {formatTime(store.timeSaved())}</div>
            <div className="text-zinc-400">Export: {formatTime(store.totalDuration())} / {formatTime(store.sourceDuration)}</div>
          </div>
        )}

        <button className="btn" disabled={store.fragments.length === 0}>
          Export
        </button>
      </div>

      {store.videoUrl ? (
        <>
          {/* Main area */}
          <div className="flex flex-1 min-h-0">
            {/* Video preview */}
            <div className="flex-1 flex items-center justify-center bg-black p-2">
              <VideoPreview />
            </div>

            {/* Right panel */}
            <div className="w-80 border-l border-zinc-800 flex flex-col bg-zinc-900">
              <SilencePanel
                isDetecting={isDetecting}
                onDetect={handleDetect}
              />
              <div className="border-t border-zinc-800 flex-1 overflow-auto">
                <FragmentList />
              </div>
            </div>
          </div>

          {/* Timeline */}
          <div className="border-t border-zinc-800">
            <Timeline />
          </div>
        </>
      ) : (
        /* Drop zone */
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center">
            <div className="text-6xl text-zinc-700 mb-4">🎬</div>
            <p className="text-xl text-zinc-400">Drop a video file here</p>
            <p className="text-sm text-zinc-600 mt-2">or click Import</p>
          </div>
        </div>
      )}
    </div>
  );
}
