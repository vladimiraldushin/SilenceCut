'use client';

import { useEditorStore } from '@/lib/store';

export function FragmentList() {
  const { fragments, selectedFragmentId, setSelectedFragment, toggleFragment, deleteFragment } = useEditorStore();

  const formatTime = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    const ms = Math.floor((s % 1) * 100);
    return `${m}:${String(sec).padStart(2, '0')}.${String(ms).padStart(2, '0')}`;
  };

  const formatDuration = (s: number) => s < 1 ? `${Math.round(s * 1000)}ms` : `${s.toFixed(1)}s`;

  if (fragments.length === 0) {
    return (
      <div className="p-4 text-center text-zinc-500 text-sm">
        <p>No fragments yet</p>
        <p className="text-xs mt-1">Import a video and detect silence</p>
      </div>
    );
  }

  return (
    <div>
      <div className="flex justify-between px-4 py-2 text-sm font-semibold border-b border-zinc-800">
        <span>Fragments</span>
        <span className="text-zinc-500">{fragments.length} total</span>
      </div>
      <div className="divide-y divide-zinc-800/50">
        {fragments.map(f => (
          <div
            key={f.id}
            onClick={() => setSelectedFragment(f.id)}
            className={`flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-zinc-800/50 transition-colors ${
              selectedFragmentId === f.id ? 'bg-blue-900/20' : ''
            }`}
          >
            {/* Type indicator */}
            <div className={`w-1 h-8 rounded-full ${f.type === 'speech' ? 'bg-green-500' : 'bg-red-400'}`} />

            {/* Toggle */}
            <button
              onClick={e => { e.stopPropagation(); toggleFragment(f.id); }}
              className={`text-lg ${f.isIncluded ? 'text-green-400' : 'text-zinc-600'}`}
            >
              {f.isIncluded ? '✓' : '○'}
            </button>

            {/* Info */}
            <div className="flex-1 min-w-0">
              <div className={`text-sm font-medium ${f.isIncluded ? '' : 'text-zinc-500 line-through'}`}>
                {f.type === 'speech' ? 'Speech' : 'Silence'}
              </div>
              <div className="text-[11px] text-zinc-500 tabular-nums">
                {formatTime(f.sourceStartTime)} — {formatTime(f.sourceStartTime + f.sourceDuration)}
              </div>
            </div>

            {/* Duration */}
            <span className={`text-xs px-1.5 py-0.5 rounded ${
              f.type === 'silence' ? 'bg-red-900/30 text-red-300' : 'bg-green-900/30 text-green-300'
            }`}>
              {formatDuration(f.sourceDuration)}
            </span>

            {/* Delete */}
            <button
              onClick={e => { e.stopPropagation(); deleteFragment(f.id); }}
              className="text-zinc-600 hover:text-red-400 text-sm"
            >
              ✕
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
