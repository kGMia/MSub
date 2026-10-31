"""Bounded M5 probe; run with PYTHONPATH=src MLX_ENABLE_TF32=0.
Synthetic signals are throughput/numerical fixtures, not a speech-quality corpus.
"""
import argparse
import json
import time
import wave
from pathlib import Path
import numpy as np
from huz_subtitle.cli import load_pyannote_mlx_segmentation_model, pyannote_mlx_forward_chunk
from huz_subtitle.pyannote_mlx import make_pyannote_forward


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio', type=Path, help='Optional mono PCM16/16k WAV; only first four windows are read')
    parser.add_argument('--frontend', choices=['numpy', 'mlx'], default='numpy')
    parser.add_argument('--model', default='models/Pyannote-Segmentation-MLX')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    rng = np.random.default_rng(42)
    windows = np.stack([np.zeros(160000), rng.normal(0, .05, 160000),
                        .1 * np.sin(np.arange(160000) * .0864), rng.normal(0, .1, 160000)]).astype(np.float32)
    if args.audio:
        with wave.open(str(args.audio)) as reader:
            if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, 16000):
                parser.error('Audio must be mono PCM16 at 16 kHz')
            for i in range(4):
                chunk = np.frombuffer(reader.readframes(160000), dtype='<i2').astype(np.float32) / 32768
                windows[i] = np.pad(chunk, (0, 160000 - len(chunk)))
    _, weights = load_pyannote_mlx_segmentation_model(args.model)
    start = time.perf_counter()
    reference = np.stack([pyannote_mlx_forward_chunk(x, weights) for x in windows])
    cpu_seconds = time.perf_counter() - start
    forward, _ = make_pyannote_forward(weights, pyannote_mlx_forward_chunk, 'mlx')
    import mlx.core as mx
    rows = []
    for size in [1, 2, 4]:
        timings = []
        mx.reset_peak_memory()
        for _ in range(3):
            start = time.perf_counter()
            actual = np.concatenate([forward.predict_batch(windows[i:i+size], frontend=args.frontend) for i in range(0, 4, size)])
            timings.append(time.perf_counter() - start)
        error = float(np.max(np.abs(actual - reference)))
        flips = int(np.count_nonzero((actual >= .5) != (reference >= .5)))
        rows.append(dict(batch=size, coldSeconds=timings[0], warmSeconds=timings[1:],
                         maxProbabilityError=error, thresholdFlips=flips,
                         parity=bool(np.allclose(actual, reference, atol=2e-5, rtol=2e-5) and flips == 0),
                         peakBytes=mx.get_peak_memory()))
    report = dict(device=mx.device_info()['device_name'], windows=4, cpuSeconds=cpu_seconds,
                  input='audio' if args.audio else 'synthetic', frontend=args.frontend, batches=rows,
                  note='Fixed windows only; not boundary-quality or end-to-end validation.')
    result = json.dumps(report, indent=2)
    if args.output: args.output.write_text(result + '\n')
    print(result)

if __name__ == '__main__':
    main()
