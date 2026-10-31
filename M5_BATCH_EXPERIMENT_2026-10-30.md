# M5 batching experiment — 2026-10-30

## Follow-up: hybrid path and actual native Qwen measurement

The sections below this update retain the original experiment history.

- Located synthetic error in the MLX SincNet frontend on all-zero audio: full GPU error7.99e-5, CPU frontend plus GPU recurrent/dense layers error2.98e-7. Experimental predict_batch now defaults to this hybrid frontend; --frontend mlx retains the comparison. Synthetic hybrid batch4 warm106.6–108.2 ms per4 windows vs CPU204.3 ms, MLX allocation peak23.6 MB. Six targeted GPU tests passed, including silence/DC/near-silence/tone and batch reorder checks.
- Added explicit production opt-in MSUB_PYANNOTE_MLX_BACKEND=mlx_batch with MLX_ENABLE_TF32=0. It reads at most4 fixed windows per batch and retains original overlap/aggregation, ordered progress, final padding and file cleanup. Default remains NumPy. On40 s of actual audio, final11 segment boundaries exactly matched CPU, max probability error6.56e-7. Cold setup makes short clips slower:0.531 s vs0.343 s CPU. No automatic threshold-based backend selection or guaranteed long-video speedup.
- Native Swift Qwen JA BF16 probe now actually ran using existing Xcode Debug package object files, without launching/changing the app. Two10 s excerpts from test.mp4, three rounds: warm separate encoding225.6–227.0 ms vs batched156.5–160.2 ms (~30% encoder time reduction); cold separate1.381 s vs batch0.216 s is order/cache biased and not a speedup claim. Output shape262×2048, max feature difference0.0006422, process MLX peak~5.05 GB. No decoder/transcript parity measured; batch reuse remains disabled. No isolated prefill/decode or NAX-kernel capture claim.
- Reusable native probe: scripts/benchmark_qwen_encoder.py --derived-data /path/to/MSub-DerivedData --model /path/to/Qwen3-ASR-1.7B-JA-MLX-bf16 --audio /path/to/mono16k-at-least20s.wav --output /tmp/qwen-encoder.json. Requires an existing Debug build and local Metal access. Compiles apps/MSub/Scripts/benchmark-qwen-encoder.swift against existing packages and uses a temporary model symlink staging directory; weights remain unchanged.
- Reports: Performance/qwen-ja-native-encoder-2026-10-30.json, pyannote-m5-hybrid-2026-10-30.json and pyannote-m5-hybrid-pipeline-2026-10-30.json.57 targeted CPU/progress/boundary checks and6 opt-in GPU checks passed.

Enable optional hybrid mode in the backend launch environment (or Xcode Run environment inherited by its Python child):

```text
MSUB_PYANNOTE_MLX_BACKEND=mlx_batch
MLX_ENABLE_TF32=0
```

TF32 is process-wide: setting it on the whole app also affects native MLX Float32 policy. Benchmark the full chosen engine combination before adopting it permanently; this does not force Neural Accelerator use. Remove these variables to return to defaults.


## Measured on the local M5 / 24 GB

Pyannote converted weights, Float32, MLX_ENABLE_TF32=0, four 10-second windows. Actual-audio run used the first40 s of repository test.mp4, extracted as mono16 kHz PCM16. Synthetic run used silence/noise/tone fixtures, not a labeled speech-quality corpus.

| Input | CPU four windows | MLX batch4 warm, four windows | Max probability error vs CPU | 0.5 decisions |
| --- | ---: | ---: | ---: | --- |
| Test audio |199.6 ms|67.1–74.3 ms|1.55e-6|identical|
| Synthetic |204.5 ms|71.4–75.5 ms|7.99e-5|identical|

Batch4 Metal allocation peak was about129.5 MB (MLX allocator metric, not total process RSS). Cold batch4 calls took about246–257 ms; warm throughput must not be presented as startup or whole-file performance. This measures GPU speed, not proof of Neural Accelerator kernel utilization. TF32 remains disabled for this validation path.

The synthetic input exceeds existing probability tolerance atol=rtol=2e-5 despite matching0.5 decisions. No default backend/batch/precision/tolerance changes. The new predict_batch method is experimental and only called by the benchmark/tests; normal production still uses NumPy or the existing opt-in single-window MLX method. Batch accepts1–4 windows exactly160000 samples and normalizes each independently. Compiled recurrent reversal uses the time axis, not the batch axis.

Reproduce from repository root:

```bash
PYTHONPATH=src MLX_ENABLE_TF32=0 .venv/bin/python scripts/benchmark_pyannote_batches.py --audio /path/to/mono16k.wav --output /tmp/pyannote-batch-report.json
```

The tool reads only four windows, not the entire audio file. Reports are saved in Performance/pyannote-m5-{speech,synthetic}-2026-10-30.json. GPU numerical/order regression (five tests, including original single-window parity) passed with MSUB_TEST_MLX_AUDIO set to the extracted test WAV. General Pyannote/streaming/performance tests:29 passed,1 opt-in skipped before enabling the two GPU checks. No broad boundary-quality corpus, Core ML conversion, or full video rerun.

## Native Qwen measurement hooks and bounded encoder prototype

Default operation now emits OSLog category QwenPerformance and signposts QwenSegment / QwenFirstText. First-text delay includes preprocessing, encoding, prefill and possible language-token buffering; after-first-text time also includes finalization. These are NOT clean encoder/prefill/decode timings. Upstream STTGenerationInfo.prefillTime is hardcoded0 and generateTime combines work, so neither is used as isolated-stage evidence.

For a deliberate encoder experiment, set this Xcode scheme Run environment variable:

```
MSUB_NATIVE_QWEN_ENCODER_PROBE=1
```

Run native Qwen on at least two detected segments. Once per request, on machines with>=16 GiB memory, the first two validated segments (each<=30 s) are preprocessed separately, encoded separately, padded with independent masks and encoded as one batch. The probe logs preprocessing time, sequential encoder time, batched encoder time, output-shape mismatch or maximum feature difference, and process-wide MLX peak memory. It runs actor-confined with explicit eval barriers; no competing model task. Numeric/timing records contain no transcript/audio contents.

This adds duplicate work and is disabled by default. Probe time is excluded from normal stage totals. The cap bounds input to two segments, not a guaranteed process-memory ceiling. Sequential and batched calls have order/cache bias; logs are a first correctness/cost probe, not a final benchmark. No real Qwen encoder probe has been executed yet in this iteration; build success does not validate runtime numerics. Disable the environment variable after collecting results.

Upstream getAudioFeatures supports batched input but generateStream does not accept preencoded features. Thus the probe does not feed batch outputs into normal decoding: production still uses its existing verified API. To turn this into an optimization, extend the upstream API for separate prefill/decode with supplied features, preserve language-prefix/EOS/repetition handling and cue ordering, then compare output and memory. Avoid a duplicated decoder or concurrent tasks sharing one model.

Use Instruments Points of Interest together with Metal System Trace for QwenSegment/QwenEncoderProbe intervals. Actual NAX kernel dispatch/GPU gaps have NOT been captured yet. Neural Accelerator saturation and isolated prefill timing remain unmeasured. Core ML/ANE placement comparisons remain future work; no model conversion was made here.
