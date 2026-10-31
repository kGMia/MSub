"""Bounded PCM reads must preserve the former full-file window/aggregation results."""
import argparse
import math
import wave

import numpy as np
import pytest

from huz_subtitle import cli, pyannote_mlx


@pytest.mark.parametrize('batch_size', [1, 4])
@pytest.mark.parametrize('length', [0, 1, 159, 160, 161, 377, 16000])
@pytest.mark.parametrize('ratio', [.1, .5, 1.0])
def test_streaming_matches_full_file_reference(tmp_path, monkeypatch, length, ratio, batch_size):
    sample_rate, chunk_samples, frame_count = 16000, 160, 7
    pcm = np.random.default_rng(42).integers(-32768, 32768, length, dtype=np.int16)
    path = tmp_path / 'audio.wav'
    with wave.open(str(path), 'wb') as writer:
        writer.setparams((1, 2, sample_rate, 0, 'NONE', 'not compressed'))
        writer.writeframes(pcm.astype('<i2').tobytes())
    monkeypatch.setattr(cli, 'load_pyannote_mlx_segmentation_model', lambda _: (
        {'sample_rate': sample_rate, 'chunk_duration': .01, 'num_frames_per_chunk': frame_count}, {}))
    monkeypatch.setenv('MSUB_PYANNOTE_MLX_STEP_RATIO', str(ratio))
    def forbidden(*args):
        pytest.fail('Pyannote must not load the entire WAV')
    monkeypatch.setattr(cli, 'read_wav_mono16', forbidden)
    observed = []
    def probabilities(chunk):
        return (chunk[:frame_count] + 1) / 2
    def forward(chunk):
        observed.append(chunk.copy())
        return probabilities(chunk)
    class BatchedForward:
        def predict_batch(self, windows):
            assert 1 <= len(windows) <= 4
            return np.stack([forward(window) for window in windows])
    selected = (BatchedForward(), 'mlx_batch') if batch_size == 4 else (forward, 'numpy')
    monkeypatch.setattr(pyannote_mlx, 'make_pyannote_forward', lambda *args: selected)
    real_open = wave.open
    readers = []
    def bounded_open(*args):
        reader = real_open(*args)
        original_read = reader.readframes
        def bounded_read(count):
            assert count <= chunk_samples
            return original_read(count)
        reader.readframes = bounded_read
        readers.append(reader)
        return reader
    monkeypatch.setattr(cli.wave, 'open', bounded_open)
    events = []
    result, frame_seconds = cli.pyannote_mlx_speech_probabilities(
        path, argparse.Namespace(pyannote_vad_model='fixture'), events.append)
    samples = pcm.astype(np.float32) / 32768.0
    step = round(chunk_samples * ratio)
    total_frames = max(frame_count, math.ceil(max(0, length - 1) / sample_rate / frame_seconds) + frame_count)
    sums, counts = np.zeros(total_frames, np.float32), np.zeros(total_frames, np.float32)
    expected_windows = []
    for start in range(0, max(1, length), step):
        window = samples[start:start + chunk_samples]
        window = np.pad(window, (0, chunk_samples - len(window)))
        expected_windows.append(window)
        offset = round(start / sample_rate / frame_seconds)
        sums[offset:offset + frame_count] += probabilities(window)
        counts[offset:offset + frame_count] += 1
        if start + chunk_samples >= length:
            break
    valid = counts > 0
    sums[valid] /= counts[valid]
    np.testing.assert_array_equal(observed, expected_windows)
    np.testing.assert_array_equal(result, sums[:np.flatnonzero(valid)[-1] + 1])
    progress = [e for e in events if e['event'] == 'vad_progress']
    assert progress[-1]['current'] == progress[-1]['total'] == len(expected_windows)
    timings = [e for e in events if e['event'] == 'vad_window_timing']
    assert 1 <= len(timings) <= 10
    assert timings[-1]['fraction'] == 1
    assert readers[0]._file is None


def test_streaming_closes_file_on_cancel(tmp_path, monkeypatch):
    path = tmp_path / 'audio.wav'
    with wave.open(str(path), 'wb') as writer:
        writer.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        writer.writeframes(bytes(640))
    monkeypatch.setattr(cli, 'load_pyannote_mlx_segmentation_model', lambda _: (
        {'chunk_duration': .01, 'num_frames_per_chunk': 7}, {}))
    monkeypatch.setattr(pyannote_mlx, 'make_pyannote_forward',
                        lambda *args: (lambda chunk: np.ones(7, np.float32), 'numpy'))
    real_open, readers = wave.open, []
    def tracking_open(*args):
        reader = real_open(*args)
        readers.append(reader)
        return reader
    monkeypatch.setattr(cli.wave, 'open', tracking_open)
    class Cancelled(Exception):
        pass
    def cancel(event):
        if event['event'] == 'vad_progress':
            raise Cancelled()
    with pytest.raises(Cancelled):
        cli.pyannote_mlx_speech_probabilities(path, argparse.Namespace(pyannote_vad_model='fixture'), cancel)
    assert readers[0]._file is None
