import { create } from 'zustand';
import { TimelineFragment, SilenceSettings, PRESETS } from './types';
import { WaveformData } from './waveform';

interface EditorState {
  // Source
  file: File | null;
  videoUrl: string | null;
  sourceDuration: number;

  // Fragments
  fragments: TimelineFragment[];
  silenceDetected: boolean;

  // Settings
  silenceSettings: SilenceSettings;

  // Timeline
  playheadPosition: number; // in edited time
  pixelsPerSecond: number;
  selectedFragmentId: string | null;
  waveformData: WaveformData | null;

  // Undo
  undoStack: TimelineFragment[][];
  redoStack: TimelineFragment[][];

  // Computed
  totalDuration: () => number;
  timeSaved: () => number;
  includedFragments: () => TimelineFragment[];

  // Actions
  setFile: (file: File) => void;
  setFragments: (fragments: TimelineFragment[]) => void;
  setSilenceSettings: (settings: Partial<SilenceSettings>) => void;
  setPlayheadPosition: (pos: number) => void;
  setPixelsPerSecond: (pps: number) => void;
  setSelectedFragment: (id: string | null) => void;
  setWaveformData: (data: WaveformData | null) => void;
  toggleFragment: (id: string) => void;
  deleteFragment: (id: string) => void;
  splitFragment: (id: string, offset: number) => void;
  removeAllSilence: () => void;
  restoreAllSilence: () => void;
  undo: () => void;
  redo: () => void;
}

function saveUndo(state: EditorState): Partial<EditorState> {
  return {
    undoStack: [...state.undoStack, state.fragments.map(f => ({ ...f }))],
    redoStack: [],
  };
}

export const useEditorStore = create<EditorState>((set, get) => ({
  file: null,
  videoUrl: null,
  sourceDuration: 0,
  fragments: [],
  silenceDetected: false,
  silenceSettings: { ...PRESETS.normal },
  playheadPosition: 0,
  pixelsPerSecond: 100,
  selectedFragmentId: null,
  waveformData: null,
  undoStack: [],
  redoStack: [],

  totalDuration: () => get().fragments.filter(f => f.isIncluded).reduce((s, f) => s + f.sourceDuration, 0),
  timeSaved: () => get().fragments.filter(f => f.type === 'silence' && !f.isIncluded).reduce((s, f) => s + f.sourceDuration, 0),
  includedFragments: () => get().fragments.filter(f => f.isIncluded),

  setFile: (file) => {
    const url = URL.createObjectURL(file);
    set({ file, videoUrl: url, fragments: [], silenceDetected: false, undoStack: [], redoStack: [] });
  },

  setFragments: (fragments) => set({ fragments, silenceDetected: true }),
  setSilenceSettings: (s) => set(state => ({ silenceSettings: { ...state.silenceSettings, ...s } })),
  setPlayheadPosition: (pos) => set({ playheadPosition: Math.max(0, pos) }),
  setPixelsPerSecond: (pps) => set({ pixelsPerSecond: Math.max(20, Math.min(500, pps)) }),
  setSelectedFragment: (id) => set({ selectedFragmentId: id }),
  setWaveformData: (data) => set({ waveformData: data }),

  toggleFragment: (id) => set(state => ({
    ...saveUndo(state),
    fragments: state.fragments.map(f => f.id === id ? { ...f, isIncluded: !f.isIncluded } : f),
  })),

  deleteFragment: (id) => set(state => ({
    ...saveUndo(state),
    fragments: state.fragments.filter(f => f.id !== id),
    selectedFragmentId: state.selectedFragmentId === id ? null : state.selectedFragmentId,
  })),

  splitFragment: (id, offset) => set(state => {
    const idx = state.fragments.findIndex(f => f.id === id);
    if (idx === -1) return {};
    const f = state.fragments[idx];
    if (offset <= 0 || offset >= f.sourceDuration) return {};
    const first: TimelineFragment = {
      ...f, id: f.id + '_a', sourceDuration: offset,
    };
    const second: TimelineFragment = {
      ...f, id: f.id + '_b',
      sourceStartTime: f.sourceStartTime + offset,
      sourceDuration: f.sourceDuration - offset,
    };
    const newFragments = [...state.fragments];
    newFragments.splice(idx, 1, first, second);
    return { ...saveUndo(state), fragments: newFragments };
  }),

  removeAllSilence: () => set(state => ({
    ...saveUndo(state),
    fragments: state.fragments.map(f => f.type === 'silence' ? { ...f, isIncluded: false } : f),
  })),

  restoreAllSilence: () => set(state => ({
    ...saveUndo(state),
    fragments: state.fragments.map(f => f.type === 'silence' ? { ...f, isIncluded: true } : f),
  })),

  undo: () => set(state => {
    if (state.undoStack.length === 0) return {};
    const prev = state.undoStack[state.undoStack.length - 1];
    return {
      fragments: prev,
      undoStack: state.undoStack.slice(0, -1),
      redoStack: [...state.redoStack, state.fragments.map(f => ({ ...f }))],
    };
  }),

  redo: () => set(state => {
    if (state.redoStack.length === 0) return {};
    const next = state.redoStack[state.redoStack.length - 1];
    return {
      fragments: next,
      redoStack: state.redoStack.slice(0, -1),
      undoStack: [...state.undoStack, state.fragments.map(f => ({ ...f }))],
    };
  }),
}));
