#!/usr/bin/env python3
"""Offline derived-copy repair; bounded delay/gain cancellation, not acoustic AEC."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import wave

import numpy as np

RATE = 16000
MAX_SECONDS = 7200
MAX_CHUNKS = 20000
MAX_MANIFEST = 8 * 1024 * 1024
MAX_CHUNK_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 1024 * 1024 * 1024
MAX_DELAY = 8000  # Positive microphone leakage delay, 0..500 ms.
BLOCK = 32000


class RepairError(Exception):
    """Only fixed non-content-bearing error codes are shown to the caller."""


def directory(path):
    path = Path(os.path.abspath(path))
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise RepairError('unsafe_directory')
    return path


def open_file(root_fd, name, maximum):
    if not isinstance(name, str) or not name or '/' in name or '\\' in name or name in ('.', '..') or '\0' in name:
        raise RepairError('unsafe_filename')
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
    except OSError:
        raise RepairError('unsafe_input_file') from None
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > maximum:
        os.close(fd)
        raise RepairError('unsafe_input_file')
    return os.fdopen(fd, 'rb')


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RepairError('invalid_timeline')
    try:
        value = float(value)
    except OverflowError:
        raise RepairError('invalid_timeline') from None
    if not math.isfinite(value) or value < 0: raise RepairError('invalid_timeline')
    return value


def load_timelines(meeting_directory):
    root = directory(meeting_directory)
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with open_file(root_fd, 'session.json', MAX_MANIFEST) as manifest:
            data = manifest.read(MAX_MANIFEST + 1)
            if len(data) > MAX_MANIFEST: raise RepairError('manifest_too_large')
            value = json.loads(data)
        chunks = value.get('chunks') if isinstance(value, dict) else None
        if not isinstance(chunks, list) or not 1 <= len(chunks) <= MAX_CHUNKS:
            raise RepairError('invalid_chunk_count')
        descriptors, names, total_bytes, end = [], set(), 0, 0
        for chunk in chunks:
            if not isinstance(chunk, dict) or chunk.get('source') not in ('meeting', 'microphone'):
                raise RepairError('invalid_source')
            name = chunk.get('filename')
            if not isinstance(name, str) or not name.endswith('.wav') or name in names:
                raise RepairError('invalid_chunk_name')
            names.add(name)
            start, duration = number(chunk.get('start')), number(chunk.get('duration'))
            if start + duration > MAX_SECONDS or not 0 < duration <= 120:
                raise RepairError('timeline_limit')
            with open_file(root_fd, name, MAX_CHUNK_BYTES) as source:
                total_bytes += os.fstat(source.fileno()).st_size
                if total_bytes > MAX_TOTAL_BYTES: raise RepairError('input_size_limit')
                with wave.open(source, 'rb') as audio:
                    if audio.getparams()[:3] != (1, 2, RATE) or audio.getcomptype() != 'NONE':
                        raise RepairError('expected_pcm16_mono_16khz')
                    frames = audio.getnframes()
                    if not 0 < frames <= 120 * RATE or abs(frames / RATE - duration) > 2 / RATE:
                        raise RepairError('chunk_duration_mismatch')
            at = round(start * RATE)
            descriptors.append((chunk['source'], at, frames, name))
            end = max(end, at + frames)
        if end > MAX_SECONDS * RATE: raise RepairError('timeline_limit')
        ordered = sorted(descriptors)
        active_ends = {'meeting': [], 'microphone': []}
        overlap_samples = overlap_segments = 0
        for source, at, frames, _ in ordered:
            active = [stop for stop in active_ends[source] if stop > at]
            if len(active) >= 2: raise RepairError('triple_source_coverage')
            if active:
                overlap = min(active[0], at + frames) - at
                if overlap > RATE: raise RepairError('overlap_exceeds_one_second')
                overlap_samples += overlap; overlap_segments += 1
            active_ends[source] = active + [at + frames]
        meeting = np.zeros(end, dtype=np.float32)
        microphone = np.zeros(end, dtype=np.float32)
        # At most two chunks may cover a sample. uint8 keeps the accumulator bounded.
        coverage = {'meeting': np.zeros(end, dtype=np.uint8), 'microphone': np.zeros(end, dtype=np.uint8)}
        for source, at, frames, name in ordered:
            with open_file(root_fd, name, MAX_CHUNK_BYTES) as handle, wave.open(handle, 'rb') as audio:
                raw = audio.readframes(frames)
                if len(raw) != frames * 2: raise RepairError('truncated_audio')
            samples = np.frombuffer(raw, dtype='<i2').astype(np.float32) / 32767
            (meeting if source == 'meeting' else microphone)[at:at + frames] += samples
            coverage[source][at:at + frames] += 1
        for source, timeline in [('meeting', meeting), ('microphone', microphone)]:
            np.maximum(coverage[source], 1, out=coverage[source])
            np.divide(timeline, coverage[source], out=timeline)
        return meeting, microphone, {
            'duration_seconds': end / RATE, 'chunks': len(chunks),
            'overlap_samples': overlap_samples, 'overlap_segments': overlap_segments,
        }
    finally:
        os.close(root_fd)


def reduce_echo(meeting, microphone):
    if meeting.ndim != 1 or microphone.shape != meeting.shape or not 0 < len(meeting) <= MAX_SECONDS * RATE:
        raise RepairError('invalid_signal_shape')
    if not np.isfinite(meeting).all() or not np.isfinite(microphone).all():
        raise RepairError('nonfinite_signal')
    cleaned = microphone.astype(np.float32, copy=True)
    delays, gains, correlations = [], [], []
    before_energy = after_energy = 0.0
    for start in range(0, len(meeting), BLOCK):
        stop = min(start + BLOCK, len(meeting))
        mic = microphone[start:stop].astype(np.float64)
        # Padding preserves the absolute start and prevents wrap-around in correlation.
        ref_start = max(0, start - MAX_DELAY)
        reference = meeting[ref_start:stop].astype(np.float64)
        padding = MAX_DELAY - (start - ref_start)
        if padding: reference = np.pad(reference, (padding, 0))
        mic_energy = float(mic @ mic)
        before_energy += mic_energy
        if len(mic) < RATE // 4 or mic_energy < len(mic) * 1e-8 or float(reference @ reference) < len(reference) * 1e-7:
            after_energy += mic_energy
            continue
        fft_size = 1 << (len(reference) + len(mic) - 2).bit_length()
        correlation = np.fft.irfft(np.fft.rfft(reference, fft_size) * np.conj(np.fft.rfft(mic, fft_size)), fft_size)[:MAX_DELAY + 1]
        energy = np.concatenate(([0.0], np.cumsum(reference * reference)))
        ref_energy = energy[len(mic):len(mic) + MAX_DELAY + 1] - energy[:MAX_DELAY + 1]
        score = np.abs(correlation) / np.sqrt(np.maximum(ref_energy * mic_energy, 1e-20))
        index = int(np.argmax(score))
        confidence = float(score[index])
        gain = float(correlation[index] / max(ref_energy[index], 1e-20))
        if confidence < 0.20 or not 0.01 <= abs(gain) <= 3.0:
            after_energy += mic_energy
            continue
        estimate = reference[index:index + len(mic)] * gain
        residual = mic - estimate
        # Owner permits aggressive reduction and loss of quiet simultaneous local speech.
        # Never gate when the reference is silent or correlation is uncertain.
        if confidence >= 0.45:
            power = np.pad(estimate * estimate, (80, 80))
            cumulative = np.concatenate(([0.0], np.cumsum(power)))
            envelope = (cumulative[160:] - cumulative[:-160])[:len(mic)] / 160
            attenuation = np.clip(envelope / 1e-6, 0, 1)
            residual *= 1 - 0.75 * attenuation
        cleaned[start:stop] = residual.astype(np.float32)
        after_energy += float(residual @ residual)
        delays.append((MAX_DELAY - index) / RATE * 1000)
        gains.append(gain); correlations.append(confidence)
    if not np.isfinite(cleaned).all(): raise RepairError('nonfinite_output')
    reduction = 10 * math.log10(max(before_energy, 1e-20) / max(after_energy, 1e-20))
    return cleaned, {
        'affected_blocks': len(delays),
        'total_blocks': math.ceil(len(meeting) / BLOCK),
        'median_delay_ms': round(float(np.median(delays)), 3) if delays else None,
        'median_gain': round(float(np.median(gains)), 5) if gains else None,
        'median_correlation': round(float(np.median(correlations)), 5) if correlations else None,
        'estimated_mic_reduction_db': round(reduction, 3),
    }


def validate_output(output):
    output = Path(os.path.abspath(output))
    if output.suffix != '.m4a' or output.name == 'meeting.m4a': raise RepairError('unsafe_output_name')
    parent = directory(output.parent)
    info = parent.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o777 != 0o700:
        raise RepairError('output_directory_requires_0700')
    if os.path.lexists(output): raise RepairError('output_already_exists')
    return output


def encode_output(output, meeting, cleaned):
    output = validate_output(output)
    encoder = shutil.which('ffmpeg')
    if not encoder: raise RepairError('ffmpeg_required_for_output')
    # Scratch files contain audio; both scratch directory and every file are private.
    with tempfile.TemporaryDirectory(prefix='axis-echo-') as raw_temp:
        scratch = Path(raw_temp)
        os.chmod(scratch, 0o700)
        wav, encoded = scratch / 'derived.wav', scratch / 'derived.m4a'
        cleaned += meeting
        peak = float(np.max(np.abs(cleaned)))
        scale = min(1.0, 0.97 / max(peak, 1e-20))
        fd = os.open(wav, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as handle, wave.open(handle, 'wb') as audio:
            audio.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
            for start in range(0, len(cleaned), BLOCK):
                audio.writeframes((np.clip(cleaned[start:start + BLOCK] * scale, -1, 1) * 32767).astype('<i2').tobytes())
        # Create the encoder target privately before starting a fixed, offline command.
        fd = os.open(encoded, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.close(fd)
        command = [str(Path(encoder).resolve()), '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                   '-protocol_whitelist', 'file,pipe', '-i', str(wav), '-map_metadata', '-1', '-vn',
                   '-ac', '1', '-ar', str(RATE), '-c:a', 'aac', '-b:a', '96k', '-f', 'ipod', str(encoded)]
        try:
            subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True, timeout=300)
        except (OSError, subprocess.SubprocessError):
            raise RepairError('local_encoder_failed') from None
        if not 0 < encoded.stat().st_size <= MAX_TOTAL_BYTES: raise RepairError('invalid_encoded_output')
        # Exclusive creation prevents races from replacing an input or an existing copy.
        parent = directory(output.parent)
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        output_fd, created_inode = None, None
        try:
            output_fd = os.open(output.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
            created_inode = os.fstat(output_fd).st_ino
            with os.fdopen(output_fd, 'wb') as target, encoded.open('rb') as source:
                output_fd = None
                shutil.copyfileobj(source, target, 1024 * 1024)
                target.flush(); os.fsync(target.fileno())
        except BaseException:
            # A newly created partial derived copy is disposable; never remove an existing file.
            if output_fd is not None: os.close(output_fd)
            if created_inode is not None:
                try:
                    if os.stat(output.name, dir_fd=parent_fd, follow_symlinks=False).st_ino == created_inode:
                        os.unlink(output.name, dir_fd=parent_fd)
                except OSError:
                    pass
            raise
        finally:
            os.close(parent_fd)
    return {'output_peak_scale': round(scale, 6), 'output_samples': len(cleaned)}


def main():
    parser = argparse.ArgumentParser(description='Offline echo attenuation into a separate private M4A; originals remain unchanged.')
    parser.add_argument('meeting_directory', type=Path)
    parser.add_argument('--analyze-only', action='store_true', help='Compute numeric estimates without writing any file')
    parser.add_argument('--output', type=Path, help='New .m4a in an existing private 0700 directory; never overwrites')
    args = parser.parse_args()
    if args.analyze_only and args.output: parser.error('--output cannot be combined with --analyze-only')
    try:
        output = args.output or args.meeting_directory / 'meeting.echo-reduced.m4a'
        if not args.analyze_only: output = validate_output(output)
        meeting, microphone, metadata = load_timelines(args.meeting_directory)
        cleaned, stats = reduce_echo(meeting, microphone)
        if not args.analyze_only: stats.update(encode_output(output, meeting, cleaned))
        print(json.dumps(dict(metadata, **stats), sort_keys=True, allow_nan=False))
        return 0
    except (RepairError, OSError, ValueError, TypeError, KeyError, wave.Error, EOFError, OverflowError, RecursionError, MemoryError):
        # No content, filenames, paths, titles or underlying decoder messages in logs.
        print('Echo repair failed: input, output or local encoder rejected. Originals unchanged.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
