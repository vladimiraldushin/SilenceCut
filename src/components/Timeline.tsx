'use client';

import { useRef, useEffect, useCallback } from 'react';
import { useEditorStore } from '@/lib/store';

export function Timeline() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const {
    fragments, playheadPosition, pixelsPerSecond, selectedFragmentId,
    waveformData, sourceDuration, setPlayheadPosition, setPixelsPerSecond, setSelectedFragment,
  } = useEditorStore();

  const included = fragments.filter(f => f.isIncluded);
  const totalDuration = included.reduce((s, f) => s + f.sourceDuration, 0);
  const displayDuration = fragments.length === 0 ? sourceDuration : totalDuration;

  // Compute fragment layouts (collapsed timeline)
  const layouts = useCallback(() => {
    const result: { id: string; x: number; width: number; type: string; duration: number; sourceStart: number }[] = [];
    let x = 0;
    for (const f of included) {
      const w = Math.max(f.sourceDuration * pixelsPerSecond, 3);
      result.push({ id: f.id, x, width: w, type: f.type, duration: f.sourceDuration, sourceStart: f.sourceStartTime });
      x += w;
    }
    return result;
  }, [included, pixelsPerSecond]);

  // Draw timeline
  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    const totalWidth = Math.max(displayDuration * pixelsPerSecond, rect.width);

    canvas.width = totalWidth * dpr;
    canvas.height = rect.height * dpr;
    canvas.style.width = `${totalWidth}px`;
    ctx.scale(dpr, dpr);

    const h = rect.height;

    // Background
    ctx.fillStyle = '#18181b';
    ctx.fillRect(0, 0, totalWidth, h);

    // Fragments
    const lay = layouts();
    for (const l of lay) {
      const isSelected = l.id === selectedFragmentId;
      ctx.fillStyle = isSelected ? '#3b82f6' : (l.type === 'speech' ? 'rgba(34,197,94,0.5)' : 'rgba(239,68,68,0.35)');
      ctx.fillRect(l.x, 4, l.width, h - 8);

      ctx.strokeStyle = isSelected ? '#ffffff' : 'rgba(0,0,0,0.15)';
      ctx.lineWidth = isSelected ? 2 : 0.5;
      ctx.strokeRect(l.x, 4, l.width, h - 8);

      // Label
      if (l.width > 50) {
        ctx.fillStyle = 'rgba(255,255,255,0.6)';
        ctx.font = '10px system-ui';
        ctx.textAlign = 'center';
        const label = l.type === 'speech' ? 'Speech' : 'Silence';
        const dur = l.duration < 1 ? `${Math.round(l.duration * 1000)}ms` : `${l.duration.toFixed(1)}s`;
        ctx.fillText(`${label}  ${dur}`, l.x + l.width / 2, h / 2 + 4);
      }
    }

    // Waveform
    if (waveformData && lay.length > 0) {
      ctx.strokeStyle = 'rgba(255,255,255,0.25)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      const midY = h / 2;
      const amp = (h / 2) * 0.8;

      for (const l of lay) {
        const fragIdx = fragments.findIndex(f => f.id === l.id);
        if (fragIdx === -1) continue;
        const frag = fragments[fragIdx];
        const startSample = Math.floor(frag.sourceStartTime * waveformData.samplesPerSecond);
        const endSample = Math.floor((frag.sourceStartTime + frag.sourceDuration) * waveformData.samplesPerSecond);

        for (let si = startSample; si < endSample && si < waveformData.peaks.length; si++) {
          const progress = (si - startSample) / Math.max(1, endSample - startSample);
          const x = l.x + progress * l.width;
          const peak = waveformData.peaks[si] * amp;
          ctx.moveTo(x, midY - peak);
          ctx.lineTo(x, midY + peak);
        }
      }
      ctx.stroke();
    }

    // Playhead
    const phx = playheadPosition * pixelsPerSecond;
    ctx.fillStyle = '#ef4444';
    ctx.beginPath();
    ctx.moveTo(phx - 7, 0);
    ctx.lineTo(phx + 7, 0);
    ctx.lineTo(phx, 10);
    ctx.closePath();
    ctx.fill();

    ctx.strokeStyle = '#ef4444';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(phx, 0);
    ctx.lineTo(phx, h);
    ctx.stroke();
  }, [fragments, included, playheadPosition, pixelsPerSecond, selectedFragmentId, waveformData, sourceDuration, displayDuration, layouts]);

  // Redraw on state changes
  useEffect(() => {
    draw();
  }, [draw]);

  // Also redraw on animation frame for smooth playhead
  useEffect(() => {
    let raf: number;
    const tick = () => {
      draw();
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [draw]);

  // Click to seek
  const handleClick = useCallback((e: React.MouseEvent<HTMLCanvasElement>) => {
    const rect = canvasRef.current?.getBoundingClientRect();
    if (!rect) return;
    const x = e.clientX - rect.left + (containerRef.current?.scrollLeft || 0);
    const time = Math.max(0, Math.min(x / pixelsPerSecond, displayDuration));
    setPlayheadPosition(time);
  }, [pixelsPerSecond, displayDuration, setPlayheadPosition]);

  const formatTimecode = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    const fr = Math.floor((s % 1) * 30);
    return `${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}:${String(fr).padStart(2, '0')}`;
  };

  return (
    <div className="bg-zinc-900">
      {/* Transport bar */}
      <div className="flex items-center gap-3 px-4 py-1.5 bg-zinc-900 border-b border-zinc-800 text-sm">
        <span className="font-mono">{formatTimecode(playheadPosition)}</span>
        <span className="text-zinc-500 font-mono">/ {formatTimecode(displayDuration)}</span>

        {fragments.length === 0 && sourceDuration > 0 && (
          <span className="text-zinc-600 text-xs">(click Detect Silence)</span>
        )}

        <div className="flex-1" />

        <button onClick={() => setPixelsPerSecond(pixelsPerSecond * 0.8)} className="text-zinc-400 hover:text-white">−</button>
        <input
          type="range"
          min={20} max={500}
          value={pixelsPerSecond}
          onChange={e => setPixelsPerSecond(Number(e.target.value))}
          className="w-24 accent-blue-500"
        />
        <button onClick={() => setPixelsPerSecond(pixelsPerSecond * 1.25)} className="text-zinc-400 hover:text-white">+</button>
      </div>

      {/* Canvas timeline */}
      <div ref={containerRef} className="overflow-x-auto" style={{ height: 120 }}>
        <canvas
          ref={canvasRef}
          onClick={handleClick}
          className="cursor-crosshair"
          style={{ height: 120 }}
        />
      </div>
    </div>
  );
}
