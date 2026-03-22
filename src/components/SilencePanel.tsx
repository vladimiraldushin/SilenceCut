'use client';

import { useEditorStore } from '@/lib/store';
import { PRESETS, SilenceSettings } from '@/lib/types';

interface Props {
  isDetecting: boolean;
  onDetect: () => void;
}

export function SilencePanel({ isDetecting, onDetect }: Props) {
  const { silenceSettings, setSilenceSettings, silenceDetected, fragments, removeAllSilence, restoreAllSilence } = useEditorStore();
  const silenceCount = fragments.filter(f => f.type === 'silence').length;
  const timeSaved = useEditorStore(s => s.timeSaved());

  const formatTime = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

  return (
    <div className="p-4 space-y-3">
      <h3 className="font-semibold">Silence Detection</h3>

      {silenceDetected && (
        <div className="flex gap-3 text-xs">
          <span className="text-orange-400">{silenceCount} pauses</span>
          <span className="text-green-400">{formatTime(timeSaved)} saved</span>
        </div>
      )}

      {/* Threshold */}
      <div>
        <div className="flex justify-between text-sm">
          <span>Threshold</span>
          <span className="text-zinc-400">{silenceSettings.thresholdDB} dB</span>
        </div>
        <input
          type="range"
          min={-60} max={-10} step={1}
          value={silenceSettings.thresholdDB}
          onChange={e => setSilenceSettings({ thresholdDB: Number(e.target.value) })}
          className="w-full accent-blue-500"
        />
        <div className="flex justify-between text-[10px] text-zinc-500">
          <span>More silence</span><span>Less silence</span>
        </div>
      </div>

      {/* Min Duration */}
      <div>
        <div className="flex justify-between text-sm">
          <span>Min Duration</span>
          <span className="text-zinc-400">{silenceSettings.minDurationSec.toFixed(1)}s</span>
        </div>
        <input
          type="range"
          min={0.1} max={2} step={0.1}
          value={silenceSettings.minDurationSec}
          onChange={e => setSilenceSettings({ minDurationSec: Number(e.target.value) })}
          className="w-full accent-blue-500"
        />
      </div>

      {/* Padding */}
      <div>
        <div className="flex justify-between text-sm">
          <span>Padding</span>
          <span className="text-zinc-400">{silenceSettings.paddingMs} ms</span>
        </div>
        <input
          type="range"
          min={0} max={500} step={10}
          value={silenceSettings.paddingMs}
          onChange={e => setSilenceSettings({ paddingMs: Number(e.target.value) })}
          className="w-full accent-blue-500"
        />
      </div>

      {/* Presets */}
      <div className="flex gap-2">
        {Object.entries(PRESETS).map(([name, preset]) => (
          <button key={name} onClick={() => setSilenceSettings(preset)} className="btn text-xs flex-1 capitalize">
            {name}
          </button>
        ))}
      </div>

      {/* Actions */}
      <button onClick={onDetect} disabled={isDetecting} className="btn btn-primary w-full">
        {isDetecting ? 'Detecting...' : 'Detect Silence'}
      </button>
      <div className="flex gap-2">
        <button onClick={removeAllSilence} className="btn flex-1 text-xs">Remove All Silence</button>
        <button onClick={restoreAllSilence} className="btn flex-1 text-xs">Restore All</button>
      </div>
    </div>
  );
}
