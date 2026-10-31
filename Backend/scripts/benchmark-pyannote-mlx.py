"""Compare one fixed VAD window; run with MLX_ENABLE_TF32=0."""
import argparse
import json
import time
from pathlib import Path

import numpy as np

from huz_subtitle.cli import (
    load_pyannote_mlx_segmentation_model,
    pyannote_mlx_forward_chunk,
    read_wav_mono16,
)
from huz_subtitle.pyannote_mlx import make_pyannote_forward

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("audio", type=Path, help="16 kHz mono WAV")
parser.add_argument("--model", default="models/Pyannote-Segmentation-MLX")
args = parser.parse_args()
_, weights = load_pyannote_mlx_segmentation_model(args.model)
samples, sample_rate = read_wav_mono16(args.audio)
if sample_rate != 16000:
    parser.error("Audio must be 16 kHz mono WAV")
samples = samples[:160000]
samples = np.pad(samples, (0, 160000 - len(samples)))
started = time.perf_counter()
reference = pyannote_mlx_forward_chunk(samples, weights)
numpy_seconds = time.perf_counter() - started
forward, _ = make_pyannote_forward(weights, pyannote_mlx_forward_chunk, "mlx")
timings = []
max_error = 0.0
for _ in range(4):
    started = time.perf_counter()
    actual = forward(samples)
    timings.append(time.perf_counter() - started)
    np.testing.assert_allclose(actual, reference, atol=2e-5, rtol=2e-5)
    np.testing.assert_array_equal(actual >= 0.5, reference >= 0.5)
    max_error = max(max_error, float(np.max(np.abs(actual - reference))))
print(json.dumps({
    "window_seconds": 10,
    "frames": len(reference),
    "max_absolute_probability_error": max_error,
    "threshold_disagreements": 0,
    "numpy_seconds": numpy_seconds,
    "mlx_cold_seconds": timings[0],
    "mlx_warm_seconds": timings[1:],
    "note": "One local window; not an end-to-end or recognition-quality benchmark.",
}, indent=2))
