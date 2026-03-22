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
  const [isExporting, setIsExporting] = useState(false);
  const [progress, setProgress] = useState(0);
  const [status, setStatus] = useState('');

  const loadAndTranscode = useCallback(async (file: File) => {
    store.setFile(file);
    setStatus(`Transcoding ${file.name} to H.264...`);

    try {
      // Upload and transcode to H.264 with frequent keyframes
      const formData = new FormData();
      formData.append('video', file);
      const res = await fetch('/api/transcode', { method: 'POST', body: formData });

      if (res.ok) {
        const blob = await res.blob();
        const transcodedFile = new File([blob], file.name.replace(/\.[^.]+$/, '.mp4'), { type: 'video/mp4' });
        const url = URL.createObjectURL(blob);
        // Update store with transcoded version (H.264, frequent keyframes)
        useEditorStore.setState({ file: transcodedFile, videoUrl: url });
        setStatus(`Ready: ${file.name} (H.264, fast seek)`);
      } else {
        // Fallback: use original file
        setStatus(`Loaded: ${file.name} (original format)`);
      }
    } catch {
      setStatus(`Loaded: ${file.name} (original format)`);
    }
  }, [store]);

  const handleFileSelect = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) loadAndTranscode(file);
  }, [loadAndTranscode]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (file && file.type.startsWith('video/')) loadAndTranscode(file);
  }, [loadAndTranscode]);

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

  const handleExport = useCallback(async () => {
    if (!store.file || store.fragments.length === 0) return;
    setIsExporting(true);
    setStatus('Uploading video for export...');

    try {
      const formData = new FormData();
      formData.append('video', store.file);
      formData.append('fragments', JSON.stringify(store.fragments));

      const response = await fetch('/api/export', {
        method: 'POST',
        body: formData,
      });

      if (!response.ok) {
        const err = await response.json();
        throw new Error(err.error || 'Export failed');
      }

      setStatus('Downloading...');
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = store.file.name.replace(/\.[^.]+$/, '') + '_edited.mp4';
      a.click();
      URL.revokeObjectURL(url);

      setStatus('Export complete!');
    } catch (err) {
      setStatus(`Export error: ${err instanceof Error ? err.message : 'Unknown'}`);
    }

    setIsExporting(false);
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

        <button
          onClick={handleExport}
          disabled={store.fragments.length === 0 || isExporting}
          className="btn btn-primary"
        >
          {isExporting ? 'Exporting...' : 'Export'}
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
