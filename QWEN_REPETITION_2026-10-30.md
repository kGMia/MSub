# Qwen phrase-loop recovery — 2026-10-30

## Finding

User reports repeated text inside a single cue in both native and Python modes. Python already supplied repetition_penalty1.05 with100-token history; native stream and custom greedy adapter used1.0. Native's old24-token/<=3unique backstop cannot catch repeated sentences with a larger vocabulary. Python's generic retry only considered empty output/confidence, so a looping Qwen result without confidence never triggered it.

Upstream pinned Swift implementation supports sign-aware repetitionPenalty/repetitionContextSize:
https://github.com/Blaizzy/mlx-audio-swift/blob/bf14ae0c26e4e85553dd989571cae29d70fa6735/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift

The Japanese checkpoint documents proper-noun/technical vocabulary fine-tuning, not a repetition-specific fix:
https://huggingface.co/neosophie/Qwen3-ASR-1.7B-JA

## Changes

- Native default1.05/100 now matches Python. Positive recent-token logits divide by penalty; negative ones multiply. Repeated indices are deduplicated; only emitted tokens in the current segment participate. Prompt/neighboring cue text is excluded. Both stream fallback and optimized single/pair decoder receive the policy. Existing <=3unique stop only applies with penalty1, matching upstream.
- Both pipelines detect substantial contiguous phrase loops (candidate period4...80 lexical characters, >=4 copies and >=24 total lexical characters). Bounded4096-character analysis with lag comparisons avoids regex backtracking. Brief repeated words/acknowledgements do not trigger. Formatting is ignored; a partial final repetition does not hide an earlier complete run.
- At most one audio retry: penalty at least1.15, recent context at least140 (Python uses existing retry environment settings). Original segment time range and token limit remain. Native reuses encoder features with a fresh decoder cache; Python reuses the extracted WAV without padding/re-extraction. Only nonempty nonlooping retry text replaces the first result. No arbitrary duplicate deletion; failed text-quality recovery retains the original. Actual inference/cancellation exceptions propagate normally. Adjacent cues are not compared/deduplicated.
- Normal segments incur a bounded text check, not another inference. Suspected loops incur one extra decode. Python disables generic confidence retry after a repetition attempt to avoid compounded retries. Native logs repetitionRetry; Python emits chunk_retry reason=repetition.

## Verification

Local JA BF16 model, same6s/10s/5s test.wav excerpts, maxTokens128. Unpenalized10s segment reproducibly yielded364 characters and a detected loop;1.05 yielded57 characters without loop. Other two cues retained17/14 characters. Forcing baseline penalty1 while enabling recovery exercised the retry: the looping cue became34 characters/nonlooping, with other cues unchanged. Default-policy optimized/stream literal final text parity passed. Warm request totals: unprotected6.132s vs protected2.233s; this is a sample with wasted loop generation, not a general ASR speedup. Timing endpoints stayed12...18,18...28,28...33. See Performance/qwen-repetition-2026-10-30.json and Scripts/benchmark-qwen-repetition.swift (root helper --repetition). First run includes model loading; do not compare cold total to warm as a performance claim.

30 targeted Python tests passed (rules, same-range single retry, empty/still-looping retry retention, cancellation propagation, existing pipeline/engine tests). CPU pytest exit prints the environment's known nanobind/Metal-device teardown warning; exit code0. Three native rule test bodies passed standalone. Metal checks verify positive/negative logit signs, duplicate token indices, context window and unmodified input tensor. No full-video or multilingual accuracy study, and no user's problematic recording supplied in this turn. Real repeated sentences can resemble loops, so the detector is a retry suspicion signal, not proof of hallucination.
