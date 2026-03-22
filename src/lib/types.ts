export interface TimelineFragment {
  id: string;
  sourceStartTime: number; // seconds in source file
  sourceDuration: number;  // seconds
  type: 'speech' | 'silence';
  isIncluded: boolean;
}

export interface SilenceSettings {
  thresholdDB: number;    // -60 to -10, default -30
  minDurationSec: number; // 0.1 to 2.0, default 0.3
  paddingMs: number;      // 0 to 500, default 100
}

export interface DetectionResult {
  fragments: TimelineFragment[];
  silenceCount: number;
  silenceDuration: number;
  processingTimeMs: number;
}

export const PRESETS = {
  aggressive: { thresholdDB: -25, minDurationSec: 0.2, paddingMs: 50 },
  normal: { thresholdDB: -30, minDurationSec: 0.3, paddingMs: 100 },
  conservative: { thresholdDB: -40, minDurationSec: 0.5, paddingMs: 200 },
} as const;
