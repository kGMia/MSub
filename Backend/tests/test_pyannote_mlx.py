import os
from pathlib import Path

import numpy as np
import pytest

from huz_subtitle.pyannote_mlx import make_pyannote_forward


def test_default_retains_cpu_reference():
    weights = {"fixture": 7}
    forward, backend = make_pyannote_forward(weights, lambda samples, w: (samples, w))
    assert backend == "numpy"
    assert forward([1, 2]) == ([1, 2], weights)


def test_invalid_backend_is_explicit():
    with pytest.raises(ValueError, match="auto, mlx, or numpy"):
        make_pyannote_forward({}, None, "typo")


def test_mlx_requires_precision_at_process_start(monkeypatch):
    monkeypatch.delenv("MLX_ENABLE_TF32", raising=False)
    with pytest.raises(ValueError, match="MLX_ENABLE_TF32=0"):
        make_pyannote_forward({}, None, "mlx")
    _, backend = make_pyannote_forward({}, None, "auto")
    assert backend == "numpy"


@pytest.mark.skipif(not os.getenv("MSUB_TEST_MLX_AUDIO"), reason="Local Metal/weights/audio parity test is opt-in")
def test_real_segmentation_probabilities_match_reference():
    from huz_subtitle.cli import (
        load_pyannote_mlx_segmentation_model,
        pyannote_mlx_forward_chunk,
        read_wav_mono16,
    )

    model = os.getenv("MSUB_TEST_PYANNOTE_MODEL", "models/Pyannote-Segmentation-MLX")
    _, weights = load_pyannote_mlx_segmentation_model(model)
    samples, sample_rate = read_wav_mono16(Path(os.environ["MSUB_TEST_MLX_AUDIO"]))
    assert sample_rate == 16000
    # Production uses fixed 10-second windows, including a zero-padded tail.
    samples = samples[:160000]
    samples = np.pad(samples, (0, 160000 - len(samples)))
    reference = pyannote_mlx_forward_chunk(samples, weights)
    forward, backend = make_pyannote_forward(weights, pyannote_mlx_forward_chunk, "mlx")
    assert backend == "mlx"
    for _ in range(2):  # Cold and compiled reuse must preserve the same result.
        actual = forward(samples)
        np.testing.assert_allclose(actual, reference, atol=2e-5, rtol=2e-5)
        np.testing.assert_array_equal(actual >= 0.5, reference >= 0.5)


@pytest.mark.skipif(not os.getenv('MSUB_TEST_MLX_AUDIO'), reason='Metal/weights/audio check is opt-in')
def test_batched_windows_match_independent_windows_and_preserve_order():
    from huz_subtitle.cli import load_pyannote_mlx_segmentation_model, read_wav_mono16
    _, weights = load_pyannote_mlx_segmentation_model('models/Pyannote-Segmentation-MLX')
    audio, _ = read_wav_mono16(Path(os.environ['MSUB_TEST_MLX_AUDIO']))
    windows = np.stack([np.pad(audio[i:i+160000], (0, max(0, i+160000-len(audio))))
                        for i in [0, 160000, 320000, 480000]])
    forward, _ = make_pyannote_forward(weights, None, 'mlx')
    independent = np.stack([forward(window) for window in windows])
    actual = forward.predict_batch(windows)
    np.testing.assert_allclose(actual, independent, atol=2e-5, rtol=2e-5)
    np.testing.assert_array_equal(actual >= .5, independent >= .5)
    reordered = forward.predict_batch(windows[[3, 0, 2, 1]])
    np.testing.assert_allclose(reordered, actual[[3, 0, 2, 1]], atol=2e-5, rtol=2e-5)
    for shape in [(5, 160000), (2, 80000), (160000,)]:
        with pytest.raises(ValueError, match='1–4'):
            forward.predict_batch(np.zeros(shape, np.float32))


@pytest.mark.skipif(not os.getenv('MSUB_TEST_MLX_AUDIO'), reason='Metal/weights check is opt-in')
def test_hybrid_batch_matches_cpu_on_constant_and_near_silent_windows():
    from huz_subtitle.cli import load_pyannote_mlx_segmentation_model, pyannote_mlx_forward_chunk
    _, weights = load_pyannote_mlx_segmentation_model('models/Pyannote-Segmentation-MLX')
    windows = np.stack([np.zeros(160000), np.full(160000, .1),
                        np.random.default_rng(7).normal(0, 1e-7, 160000),
                        .1 * np.sin(np.arange(160000) * .0864)]).astype(np.float32)
    reference = np.stack([pyannote_mlx_forward_chunk(x, weights) for x in windows])
    forward, backend = make_pyannote_forward(weights, None, 'mlx_batch')
    assert backend == 'mlx_batch'
    actual = forward.predict_batch(windows)
    np.testing.assert_allclose(actual, reference, atol=2e-5, rtol=2e-5)
    np.testing.assert_array_equal(actual >= .5, reference >= .5)
