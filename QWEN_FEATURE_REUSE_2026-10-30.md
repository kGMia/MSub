# Native Qwen feature reuse — 2026-10-30

**Later update:** default repetition policy is now1.05/100 with bounded same-audio recovery; historical penalty1 benchmark results below describe the earlier implementation. See QWEN_REPETITION_2026-10-30.md.

## Greedy decoding follow-up (2026-10-30)

Single-segment native Qwen now uses the same public-API greedy adapter as paired features when the expected Embedding module and audio-feature count match. It omits per-token tokenizer decoding/AsyncThrowingStream events unused by the completed-cue UI; onCue still publishes immediately after each completed segment. Token selection is evaluated together with model output rather than separately synchronizing full logits and argmax, selected tokens remain on device for the next input, and reaching maxTokens skips the unused final forward pass. EOS, low-diversity backstop, language stripping, context, wrapping and timestamp handling remain the pinned upstream contract.

`MSUB_NATIVE_QWEN_STREAM_REFERENCE=1` forces the original stream decoder and disables paired encoding for diagnosis. Unsupported module/feature shape uses the original stream automatically. This narrow adapter must be reviewed when updating mlx-audio-swift generation semantics. This is greedy inference only; it does not introduce speculative decoding or concurrent GPU model tasks.

The benchmark now warms both new paths, interleaves reference/single/pair runs and additionally compares Japanese/auto language with context and token limits1/32. See `Performance/qwen-ja-decoding-2026-10-30.json`. No full-video recognition or model-quality claim.

Final uncontended warmed comparison: reference5.963/5.913 s (mean5.938), optimized single5.898/5.849 s (mean5.873), paired5.857/5.834 s (mean5.846). Single improvement ~1.1%, paired~1.6% on this fixture only; two repetitions per mode are insufficient for a broad performance claim. First cue single0.672/0.680 s vs reference0.681/0.685 s; pair0.800/0.802 s. All six timed text comparisons and all four context/language/token-limit comparisons passed. Odd-tail times/live events, checkpoint cancellation/retry and empty input passed. Batch remains default-off; lightweight single greedy decoding is enabled. Process-wide MLX peak4.918 GB.

## Production integration and service tests (2026-10-30 evening)

The native Qwen settings now expose **Batch audio encoding (experimental)**, persisted independently and off by default. It is captured into immutable per-request options, so changing the toggle does not alter an in-flight task. `MSUB_NATIVE_QWEN_BATCH_SIZE=2` still forces on; any other explicitly set value forces off. Remove the environment variable to use the UI toggle. Existing >=16 GiB, memory-pressure cooldown, shape/module fallback and single-tail guards remain.

Measured the actual production service/support/residency sources with the local JA BF16 model on Apple M5. Three consecutive segments (6 s,10 s,5 s), maxTokens128, Japanese, line wrap30, absolute offset12 s. Warm order pair/single/single/pair, after one cold single run:

| Mode | Whole-request seconds | First completed cue seconds |
| --- | --- | --- |
| Single | 5.923 / 5.969 | 0.682 / 0.681 |
| Pair | 5.933 / 5.958 | 0.824 / 0.803 |

Mean throughput is effectively equal (~5.94 s); no end-to-end speedup claim. First cue is ~0.13 s later in pair mode. Cold single request10.566 s includes model load. Process-wide MLX peak4.918 GB is not a per-mode comparison. Short fixture only, not a representative long Japanese corpus; Debug package objects, no Instruments utilization measurement.

All four warm runs matched literal reference text. Verified cue/progress interleaving, exact absolute start/end times, odd unpaired tail, cancellation thrown at the checkpoint after the first completed cue, successful subsequent request with identical results, and empty VAD output. This does not cover cancellation midway through a Metal kernel or injected OS memory pressure. UI interaction was not automated.

Reproducible runner: `scripts/benchmark_qwen_encoder.py --pipeline --derived-data <Xcode DerivedData> --model <JA model> --audio <mono16k WAV with at least21s> --output <report.json>`. It compiles actual production sources with only DTO stand-ins, clears experimental environment overrides, and reports no transcript content. Report: `Performance/qwen-ja-pipeline-2026-10-30.json`.

The initial sandbox GPU attempt exposed a separate error-cleanup defect: clearing the MLX allocator before a successful Metal runtime check can initialize MLX with no available device and abort. `clearModel` now skips allocator access until runtime validation has succeeded. Final Xcode build passed10.847 s, no errors (20261030-213803).

Decision: keep pair encoding opt-in, accessible through the native UI. Further optimization should profile sequential token decoding/prefill, which dominates this fixture, rather than promote encoder-only gains as whole-request gains.


## Implemented as an explicit opt-in

Set `MSUB_NATIVE_QWEN_BATCH_SIZE=2` in Xcode scheme Run environment, then relaunch. Leave `MSUB_NATIVE_QWEN_ENCODER_PROBE` unset for normal processing: that older diagnostic deliberately repeats work.

On machines with >=16 GiB memory and outside the memory-pressure cooldown, the service encodes at most two validated segments (each<=30 s) together. Features are split using preprocessing audio-token counts, with a shape-sum guard. Missing public `model.embed_tokens` Embedding module, invalid batch lengths or unexpected feature count leaves the existing stream path active. Unpaired tail segments also use the existing path. Default remains unchanged.

The adapter uses public `namedModules`, `buildPrompt`, `mergeAudioFeatures`, `makeCache` and `callAsFunction` APIs; no modification to downloaded package sources. QuantizedEmbedding inherits Embedding, so module lookup does not replace it with a raw weight gather. Only greedy parameters currently used by NativeQwenService are supported: temperature0, repetitionPenalty1, EOS151645/151643,24-token <=3-unique backstop, caller's context/language/token limit. Auto-language final prefix stripping matches the pinned upstream implementation. Future dependency or generation-policy updates must revalidate this adapter.

Decode stays sequential and model/features remain actor-confined. The existing bounded decode task drains before cancellation cleanup; unused encoded features are removed in finishRequest for success/error/cancellation. Per-segment transient allocator clearing is retained. Completed cues still arrive through onCue before progress, with original ranges/timeOffset. Two-segment encoding can slightly delay first-cue availability; this is a throughput experiment, not a first-token latency promise. Waveform/timestamp synchronization fixes are unchanged.

Additional signposts: QwenBatchEncoder, QwenPreparedPrefill, QwenPreparedDecode. Prepared-prefill time includes embedding splice/evaluation overhead; generation time includes token selection/decode loop. These provide trace boundaries but no Instruments/NAX-utilization capture was made in this iteration.

## Limited local verification

Actual local JA BF16 model,6 s and10 s test.mp4 excerpts; explicit Japanese and auto language. Standard upstream stream, independently encoded-feature adapter and batched-feature adapter returned identical literal final text in all4 cases. maxTokens128, including a case reaching the limit; equality is not a recognition-quality assessment. Batch decode timings exclude the shared encoder and cannot be compared to reference total time as end-to-end speedups. The earlier ~30% gain applies only to the encoder benchmark.

JSON: Performance/qwen-ja-feature-decode-parity-2026-10-30.json. Reproduce with scripts/benchmark_qwen_encoder.py --decode and existing --derived-data/--model/--audio/--output arguments. Swift source: Scripts/benchmark-qwen-decode.swift. The benchmark reads only two bounded audio windows and prints comparisons/counts/timings, not transcripts.

Actual production NativeQwenService, with the optional mode enabled and two5 s segments, emitted both live cue callbacks before final progress and kept12 s timeOffset. This standalone harness used production service/support/residency sources with minimal DTO stand-ins, not full UI interaction. Xcode BuildProject passed20.631 s without errors (20261030-161203), Python helper syntax and diff checks pass. No full-video transcription, cancellation stress test, multilingual corpus, general8bit model validation or broad Swift test suite.

## Next validation

Use a short representative Japanese recording first, compare mode2 against default, including final text, segment timing, first-cue delay and total duration. Then check odd segment count, empty results, cancellation/resume and memory pressure on longer media before considering automatic enablement. Do not enable every GPU experimental flag together: Pyannote's explicit TF32=0 setting is process-wide and changes native Float32 MLX policy too.
