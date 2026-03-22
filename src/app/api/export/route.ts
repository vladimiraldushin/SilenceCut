import { NextRequest, NextResponse } from 'next/server';
import { writeFile, unlink, readFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { randomUUID } from 'crypto';

const execFileAsync = promisify(execFile);

interface Fragment {
  sourceStartTime: number;
  sourceDuration: number;
  isIncluded: boolean;
}

export async function POST(req: NextRequest) {
  const tmpDir = join('/tmp', 'silencecut-' + randomUUID());

  try {
    const formData = await req.formData();
    const file = formData.get('video') as File;
    const fragmentsJson = formData.get('fragments') as string;

    if (!file || !fragmentsJson) {
      return NextResponse.json({ error: 'Missing video or fragments' }, { status: 400 });
    }

    const fragments: Fragment[] = JSON.parse(fragmentsJson);
    const included = fragments.filter(f => f.isIncluded);

    if (included.length === 0) {
      return NextResponse.json({ error: 'No fragments to export' }, { status: 400 });
    }

    // Create temp directory
    await mkdir(tmpDir, { recursive: true });

    // Save uploaded file
    const inputPath = join(tmpDir, 'input' + getExtension(file.name));
    const buffer = Buffer.from(await file.arrayBuffer());
    await writeFile(inputPath, buffer);

    // Build FFmpeg concat filter
    // Method: use -filter_complex with trim + concat
    const filterParts: string[] = [];
    const concatInputs: string[] = [];

    for (let i = 0; i < included.length; i++) {
      const f = included[i];
      const start = f.sourceStartTime;
      const end = start + f.sourceDuration;

      // Trim video and audio for each fragment
      filterParts.push(
        `[0:v]trim=start=${start}:end=${end},setpts=PTS-STARTPTS[v${i}];` +
        `[0:a]atrim=start=${start}:end=${end},asetpts=PTS-STARTPTS[a${i}];`
      );
      concatInputs.push(`[v${i}][a${i}]`);
    }

    // Concat all fragments
    const filterComplex =
      filterParts.join('') +
      `${concatInputs.join('')}concat=n=${included.length}:v=1:a=1[outv][outa]`;

    const outputPath = join(tmpDir, 'output.mp4');

    // Run FFmpeg
    console.log(`[Export] Processing ${included.length} fragments...`);
    const startTime = Date.now();

    await execFileAsync('ffmpeg', [
      '-i', inputPath,
      '-filter_complex', filterComplex,
      '-map', '[outv]',
      '-map', '[outa]',
      '-c:v', 'libx264',
      '-preset', 'fast',
      '-crf', '23',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-movflags', '+faststart',
      '-y',
      outputPath,
    ], { maxBuffer: 1024 * 1024 * 10 });

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    console.log(`[Export] Done in ${elapsed}s`);

    // Read output and return
    const outputBuffer = await readFile(outputPath);

    // Cleanup
    cleanup(tmpDir);

    return new NextResponse(outputBuffer, {
      headers: {
        'Content-Type': 'video/mp4',
        'Content-Disposition': `attachment; filename="${getOutputName(file.name)}"`,
        'Content-Length': String(outputBuffer.length),
      },
    });

  } catch (error) {
    console.error('[Export] Error:', error);
    cleanup(tmpDir);
    const msg = error instanceof Error ? error.message : 'Export failed';
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}

function getExtension(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot) : '.mp4';
}

function getOutputName(name: string): string {
  const dot = name.lastIndexOf('.');
  const base = dot >= 0 ? name.substring(0, dot) : name;
  return `${base}_edited.mp4`;
}

async function cleanup(dir: string) {
  try {
    const { rm } = await import('fs/promises');
    await rm(dir, { recursive: true, force: true });
  } catch { /* ignore */ }
}

// Increase body size limit for video uploads
export const config = {
  api: {
    bodyParser: false,
  },
};
