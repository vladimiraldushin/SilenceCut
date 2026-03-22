import { NextRequest, NextResponse } from 'next/server';
import { writeFile, readFile, mkdir } from 'fs/promises';
import { join } from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { randomUUID } from 'crypto';

const execFileAsync = promisify(execFile);

/**
 * Transcode uploaded video to H.264 with frequent keyframes.
 * This makes seeking near-instant (keyframe every 0.5s vs 2-5s for HEVC).
 * Returns the transcoded MP4 file.
 */
export async function POST(req: NextRequest) {
  const tmpDir = join('/tmp', 'silencecut-transcode-' + randomUUID());

  try {
    const formData = await req.formData();
    const file = formData.get('video') as File;
    if (!file) {
      return NextResponse.json({ error: 'No file' }, { status: 400 });
    }

    await mkdir(tmpDir, { recursive: true });

    // Save input
    const ext = file.name.includes('.') ? file.name.substring(file.name.lastIndexOf('.')) : '.mp4';
    const inputPath = join(tmpDir, `input${ext}`);
    const buffer = Buffer.from(await file.arrayBuffer());
    await writeFile(inputPath, buffer);

    const outputPath = join(tmpDir, 'output.mp4');

    console.log(`[Transcode] Converting ${file.name} to H.264 with frequent keyframes...`);
    const startTime = Date.now();

    // Transcode to H.264 with keyframe every 15 frames (0.5s at 30fps)
    // -preset ultrafast for speed, -crf 23 for reasonable quality
    // -g 15 = keyframe interval (makes seeking fast)
    await execFileAsync('ffmpeg', [
      '-i', inputPath,
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-crf', '23',
      '-g', '15',           // keyframe every 15 frames = ~0.5s
      '-keyint_min', '15',  // minimum keyframe interval
      '-c:a', 'aac',
      '-b:a', '128k',
      '-movflags', '+faststart',
      '-y',
      outputPath,
    ], { maxBuffer: 1024 * 1024 * 50, timeout: 300000 });

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    console.log(`[Transcode] Done in ${elapsed}s`);

    const outputBuffer = await readFile(outputPath);

    // Cleanup
    try {
      const { rm } = await import('fs/promises');
      await rm(tmpDir, { recursive: true, force: true });
    } catch { /* ignore */ }

    return new NextResponse(outputBuffer, {
      headers: {
        'Content-Type': 'video/mp4',
        'Content-Length': String(outputBuffer.length),
      },
    });

  } catch (error) {
    console.error('[Transcode] Error:', error);
    try {
      const { rm } = await import('fs/promises');
      await rm(tmpDir, { recursive: true, force: true });
    } catch { /* ignore */ }
    return NextResponse.json(
      { error: error instanceof Error ? error.message : 'Transcode failed' },
      { status: 500 }
    );
  }
}
