declare module 'mp4box' {
  interface MP4Info {
    duration: number;
    timescale: number;
    tracks: MP4Track[];
  }

  interface MP4Track {
    id: number;
    type: string;
    codec: string;
    nb_samples: number;
    timescale: number;
    duration: number;
    movie_duration: number;
    movie_timescale: number;
    video?: { width: number; height: number };
    audio?: { sample_rate: number; channel_count: number };
  }

  interface MP4Sample {
    number: number;
    track_id: number;
    timescale: number;
    description: { avcC?: ArrayBuffer; hvcC?: ArrayBuffer };
    data: ArrayBuffer;
    size: number;
    duration: number;
    cts: number;
    dts: number;
    is_sync: boolean;
    is_leading: number;
    depends_on: number;
    is_depended_on: number;
    has_redundancy: number;
    degradation_priority: number;
    offset: number;
    subsamples: unknown;
  }

  interface MP4File {
    onReady: ((info: MP4Info) => void) | null;
    onSamples: ((trackId: number, ref: unknown, samples: MP4Sample[]) => void) | null;
    onError: ((e: Error) => void) | null;
    appendBuffer(buffer: ArrayBuffer & { fileStart?: number }): number;
    start(): void;
    stop(): void;
    flush(): void;
    setExtractionOptions(trackId: number, ref?: unknown, options?: { nbSamples?: number }): void;
    getTrackById(id: number): MP4Track;
    getInfo(): MP4Info;
  }

  function createFile(): MP4File;
  export { createFile, MP4File, MP4Info, MP4Track, MP4Sample };
}
