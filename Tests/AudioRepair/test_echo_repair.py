"""Synthetic fixtures only. Never reads a user's meeting archive."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import wave

import numpy as np

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts' / 'repair-echo.py'
spec = importlib.util.spec_from_file_location('repair_echo', SCRIPT)
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class EchoRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        os.chmod(self.root, 0o700)

    def tearDown(self):
        self.temp.cleanup()

    def wav(self, name, signal, rate=16000):
        path = self.root / name
        with wave.open(str(path), 'wb') as out:
            out.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
            out.writeframes((np.clip(signal, -1, 1) * 32767).astype('<i2').tobytes())
        return path

    def fixture(self):
        rng = np.random.default_rng(71)
        n = 8 * 16000
        # Broadband coloured reference with a speech-like amplitude envelope.
        remote = np.convolve(rng.normal(0, 0.13, n), np.ones(4) / 4, 'same')
        remote[4 * 16000:] = 0
        delay = 1371
        echo = np.concatenate([np.zeros(delay), remote[:-delay]]) * 0.63
        local = np.zeros(n)
        t = np.arange(3 * 16000) / 16000
        local[5 * 16000:] = 0.15 * np.sin(2 * np.pi * (173 * t + 9 * t * t))
        self.wav('meeting.wav', remote)
        self.wav('microphone.wav', echo + local)
        manifest = {'chunks': [
            {'source': 'meeting', 'start': 0, 'duration': 8, 'filename': 'meeting.wav'},
            {'source': 'microphone', 'start': 0, 'duration': 8, 'filename': 'microphone.wav'},
        ]}
        (self.root / 'session.json').write_text(json.dumps(manifest))
        return remote, local, echo

    def test_groundtruth_echo_reduction_and_microphone_only(self):
        remote, local, echo = self.fixture()
        meeting, mic, meta = repair.load_timelines(self.root)
        before = mic.copy()
        cleaned, stats = repair.reduce_echo(meeting, mic)
        region = slice(16000, 4 * 16000)
        reduction = 10 * np.log10(np.mean(before[region] ** 2) / max(np.mean(cleaned[region] ** 2), 1e-15))
        self.assertGreater(reduction, 25)
        np.testing.assert_array_equal(cleaned[5 * 16000:], before[5 * 16000:])
        self.assertEqual(len(cleaned), len(remote))
        self.assertTrue(np.isfinite(cleaned).all())
        self.assertLessEqual(abs(stats['median_delay_ms'] - 1371 / 16), 1)
        self.assertGreater(stats['affected_blocks'], 0)

    def test_simple_reverberation_and_overlap_remain_finite(self):
        remote, local, echo = self.fixture()
        # A second acoustic reflection is deliberately outside the one-delay model.
        reflection = np.concatenate([np.zeros(1531), remote[:-1531]]) * 0.17
        mixture = (echo + reflection + local).astype(np.float32)
        cleaned, stats = repair.reduce_echo(remote.astype(np.float32), mixture)
        region = slice(16000, 4 * 16000)
        ratio = np.mean(mixture[region] ** 2) / max(np.mean(cleaned[region] ** 2), 1e-15)
        self.assertGreater(10 * np.log10(ratio), 15)
        self.assertTrue(np.isfinite(cleaned).all())
        # Quiet simultaneous local speech can be attenuated; no preservation claim for it.
        overlap = mixture + np.random.default_rng(12).normal(0, 0.006, len(mixture))
        overlapping, _ = repair.reduce_echo(remote.astype(np.float32), overlap.astype(np.float32))
        self.assertTrue(np.isfinite(overlapping).all())
        self.assertEqual(len(overlapping), len(remote))

    def test_chunk_alignment_gaps_and_sources_remain_unchanged(self):
        self.wav('a.wav', np.full(1600, 0.1))
        self.wav('b.wav', np.full(3200, 0.2))
        manifest = {'chunks': [
            {'source': 'meeting', 'start': 0.2, 'duration': 0.1, 'filename': 'a.wav'},
            {'source': 'microphone', 'start': 0.5, 'duration': 0.2, 'filename': 'b.wav'}]}
        (self.root / 'session.json').write_text(json.dumps(manifest))
        originals = {p.name: p.read_bytes() for p in self.root.iterdir()}
        meeting, mic, _ = repair.load_timelines(self.root)
        self.assertEqual(len(meeting), 11200)
        self.assertTrue(np.all(meeting[:3200] == 0))
        self.assertTrue(np.all(mic[:8000] == 0))
        for name, data in originals.items():
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_bounded_multiplex_overlaps_are_averaged_without_timeline_shift(self):
        self.wav('r1.wav', np.full(16000, 0.1))
        self.wav('r2.wav', np.full(16000, 0.3))
        self.wav('m1.wav', np.full(16000, 0.2))
        self.wav('m2.wav', np.full(16000, 0.4))
        chunks = [
            {'source': 'meeting', 'start': 0, 'duration': 1, 'filename': 'r1.wav'},
            {'source': 'meeting', 'start': 0.75, 'duration': 1, 'filename': 'r2.wav'},
            {'source': 'microphone', 'start': 3, 'duration': 1, 'filename': 'm1.wav'},
            {'source': 'microphone', 'start': 3.75, 'duration': 1, 'filename': 'm2.wav'}]
        manifest = self.root / 'session.json'
        manifest.write_text(json.dumps({'chunks': chunks}))
        originals = {p.name: p.read_bytes() for p in self.root.iterdir()}
        meeting, mic, metadata = repair.load_timelines(self.root)
        self.assertEqual(len(meeting), 76000)
        self.assertEqual(metadata['overlap_samples'], 8000)
        self.assertEqual(metadata['overlap_segments'], 2)
        np.testing.assert_allclose(meeting[12000:16000], 0.2, atol=1 / 32767)
        np.testing.assert_allclose(mic[60000:64000], 0.3, atol=1 / 32767)
        self.assertTrue(np.all(meeting[28000:] == 0))
        clean, _ = repair.reduce_echo(meeting, mic)
        np.testing.assert_array_equal(clean[48000:], mic[48000:])
        manifest.write_text(json.dumps({'chunks': list(reversed(chunks))}))
        reversed_meeting, reversed_mic, reversed_meta = repair.load_timelines(self.root)
        np.testing.assert_array_equal(reversed_meeting, meeting)
        np.testing.assert_array_equal(reversed_mic, mic)
        self.assertEqual(metadata, reversed_meta)
        manifest.write_bytes(originals['session.json'])
        for name, data in originals.items(): self.assertEqual((self.root / name).read_bytes(), data)

    def test_large_overlap_triple_coverage_and_missing_last_chunk_are_rejected(self):
        for name in ['a.wav', 'b.wav', 'c.wav']:
            self.wav(name, np.zeros(32000))
        manifest = self.root / 'session.json'
        base = {'source': 'microphone', 'start': 0, 'duration': 2, 'filename': 'a.wav'}
        for other in [
            [{'source': 'microphone', 'start': 0.5, 'duration': 2, 'filename': 'b.wav'}],
            [{'source': 'microphone', 'start': 1, 'duration': 2, 'filename': 'b.wav'},
             {'source': 'microphone', 'start': 1.5, 'duration': 2, 'filename': 'c.wav'}]]:
            manifest.write_text(json.dumps({'chunks': [base, *other]}))
            with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)
        # Exactly one second is supported, including the final endpoint.
        manifest.write_text(json.dumps({'chunks': [base, {'source': 'microphone', 'start': 1, 'duration': 2, 'filename': 'b.wav'}]}))
        meeting, mic, metadata = repair.load_timelines(self.root)
        self.assertEqual(len(mic), 48000)
        self.assertEqual(metadata['overlap_samples'], 16000)
        (self.root / 'b.wav').unlink()
        with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)
        self.assertFalse((self.root / 'meeting.echo-reduced.m4a').exists())

    def test_analyze_only_writes_nothing_and_prints_only_metrics(self):
        self.fixture()
        originals = {p.name: p.read_bytes() for p in self.root.iterdir()}
        result = subprocess.run([shutil.which('python3'), str(SCRIPT), str(self.root), '--analyze-only'], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b'')
        stats = json.loads(result.stdout)
        self.assertIn('estimated_mic_reduction_db', stats)
        self.assertNotIn(str(self.root), result.stdout.decode())
        self.assertEqual(originals, {p.name: p.read_bytes() for p in self.root.iterdir()})

    def test_bad_manifest_paths_links_overlap_and_rate_are_rejected(self):
        self.fixture()
        manifest_path = self.root / 'session.json'
        original = json.loads(manifest_path.read_text())
        for bad in ['../meeting.wav', '/etc/passwd', 'session.json']:
            data = json.loads(json.dumps(original))
            data['chunks'][0]['filename'] = bad
            manifest_path.write_text(json.dumps(data))
            with self.assertRaises(repair.RepairError):
                repair.load_timelines(self.root)
        for field, value in [('start', float('nan')), ('start', -1), ('duration', 1000000), ('start', True), ('start', 10 ** 1000)]:
            data = json.loads(json.dumps(original)); data['chunks'][0][field] = value
            manifest_path.write_text(json.dumps(data))
            with self.assertRaises(repair.RepairError):
                repair.load_timelines(self.root)
        data = json.loads(json.dumps(original)); data['chunks'].append(data['chunks'][0])
        manifest_path.write_text(json.dumps(data))
        with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)
        manifest_path.write_text(json.dumps(original))
        (self.root / 'meeting.wav').unlink()
        (self.root / 'meeting.wav').symlink_to(self.root / 'microphone.wav')
        with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)
        (self.root / 'meeting.wav').unlink()
        os.link(self.root / 'microphone.wav', self.root / 'meeting.wav')
        with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)
        (self.root / 'meeting.wav').unlink()
        self.wav('meeting.wav', np.zeros(8000), rate=8000)
        with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)
        manifest_path.unlink(); manifest_path.symlink_to(self.root / 'microphone.wav')
        with self.assertRaises(repair.RepairError): repair.load_timelines(self.root)

    def test_directory_links_and_public_output_directory_are_rejected(self):
        self.fixture()
        alias = self.root / 'alias'; alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(repair.RepairError): repair.load_timelines(alias)
        public = self.root / 'public'; public.mkdir(mode=0o755)
        os.chmod(public, 0o755)
        with self.assertRaises(repair.RepairError): repair.validate_output(public / 'derived.m4a')
        truncated = self.root / 'meeting.wav'
        truncated.write_bytes(b'RIFF')
        result = subprocess.run([shutil.which('python3'), str(SCRIPT), str(self.root), '--analyze-only'], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b'Traceback', result.stderr)
        self.assertNotIn(str(self.root).encode(), result.stderr)

    def test_silence_and_uncorrelated_signals_do_not_trigger(self):
        zeros = np.zeros(32000, dtype=np.float32)
        local = np.random.default_rng(9).normal(0, 0.1, len(zeros)).astype(np.float32)
        cleaned, stats = repair.reduce_echo(zeros, local.copy())
        np.testing.assert_array_equal(cleaned, local)
        self.assertEqual(stats['affected_blocks'], 0)
        cleaned, stats = repair.reduce_echo(local, np.random.default_rng(10).normal(0, 0.1, len(zeros)).astype(np.float32))
        self.assertEqual(stats['affected_blocks'], 0)
        with self.assertRaises(repair.RepairError): repair.reduce_echo(zeros, np.full(32000, np.nan))

    @unittest.skipUnless(shutil.which('ffmpeg'), 'ffmpeg unavailable')
    def test_real_encoder_private_output_duration_and_no_overwrite(self):
        self.fixture()
        originals = {p.name: p.read_bytes() for p in self.root.iterdir()}
        result = subprocess.run([shutil.which('python3'), str(SCRIPT), str(self.root)], capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / 'meeting.echo-reduced.m4a'
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertGreater(output.stat().st_size, 100)
        decoded = self.root / 'check.wav'
        subprocess.run([shutil.which('ffmpeg'), '-nostdin', '-v', 'error', '-i', str(output), '-ac', '1', '-ar', '16000', str(decoded)], check=True, timeout=30, capture_output=True)
        with wave.open(str(decoded)) as audio:
            self.assertLess(abs(audio.getnframes() / 16000 - 8), 0.1)
        for name, data in originals.items(): self.assertEqual((self.root / name).read_bytes(), data)
        before = output.read_bytes()
        again = subprocess.run([shutil.which('python3'), str(SCRIPT), str(self.root)], capture_output=True, timeout=30)
        self.assertNotEqual(again.returncode, 0)
        self.assertEqual(output.read_bytes(), before)
        for unsafe in [self.root / 'meeting.wav', self.root / 'session.json']:
            with self.assertRaises(repair.RepairError): repair.validate_output(unsafe)
        linked = self.root / 'linked.m4a'; linked.symlink_to(self.root / 'meeting.wav')
        with self.assertRaises(repair.RepairError): repair.validate_output(linked)


if __name__ == '__main__':
    unittest.main()
