# SwiftUI and M5 acceleration — 2026-10-30

## Implemented

- TimelineZoomSlider now uses SwiftUI Slider instead of an NSSlider subclass/coordinator. Preserves logarithmic mapping, clamping, optional rounding, continuous binding, editing-state callbacks and existing labels/help. Clears dragging when removed and exposes actual zoom to accessibility. Text editing remains NSTextView: composition protection, programmatic UTF-16 selection, activation and custom undo ownership must survive any future TextEditor migration. AVPlayerView retains inline/fullscreen controls; replacing it with VideoPlayer requires checking those interactions first.
- NumPy Pyannote LSTM activates all gate values in one vectorized call per timestep rather than three separate calls, using tanh for the candidate cell as before. This does compute unused sigmoid values for the candidate slice but avoids two Python/NumPy dispatches; no model, precision, overlap, or threshold changes.
- Actual local Pyannote weights, 40 alternating silent/random 10-second windows per variant: baseline mean69.72 ms, new49.91 ms (~28% reduction). All output probability arrays identical in this probe. This is a limited CPU inference comparison, not a long-video/end-to-end or GPU utilization measurement. Probe: /tmp/msub-pyannote-fused-probe.py.
- 39 targeted Python checks passed, one real MLX opt-in test skipped. Xcode BuildProject passed23.742 s without errors (20261030-105059); final accessibility-only modifier subsequently checked by another incremental build. Manual slider/keyboard/VoiceOver checks left to user.

## What M5 acceleration means here

GPU Neural Accelerators are separate from the standalone Neural Engine. Apple's MLX explanation says MLX uses TensorOps/MPP on macOS26.2+; dense matrix-heavy prefill benefits differently from bandwidth-bound autoregressive decoding. Its LLM benchmark is not an ASR performance promise.

Inspected current pinned mlx-swift0.31.6 Cmlx sources, not merely latest upstream: device.h checks OS26.2 and hardware architecture in is_nax_available(); matmul.cpp routes eligible dtypes/operations to NAX kernels. Local package/app settings have no MLX_METAL_NO_NAX override. Qwen BF16 operations are eligible where dimensions/dispatch support them. This establishes implementation support, not proof of a measured hardware-utilization percentage. Float32 routing has TF32 conditions; do not change global precision solely to chase utilization.

Native FireRedVAD requests cpuAndNeuralEngine. That allows Core ML to place supported operations on ANE, with CPU fallback; it excludes GPU and does not mean GPU Neural Accelerators are disabled for MLX Qwen. Avoid indiscriminately changing it to all and competing with ASR for GPU resources.

Pyannote's production default remains NumPy CPU. Its opt-in MLX implementation uses sequential recurrent steps and currently requires MLX_ENABLE_TF32=0 for numerical validation. Moving this unchanged onto a GPU is not sufficient to ensure better throughput or Neural Accelerator use.

Sources:
- https://machinelearning.apple.com/research/exploring-llms-mlx-m5
- https://developer.apple.com/videos/play/tech-talks/111432/
- https://developer.apple.com/videos/play/wwdc2026/330/

## Next steps, in order

1. Measure Qwen encoder/prefill separately from decode using Instruments/Metal capture and existing timing diagnostics. Check actual NAX kernels, GPU gaps, memory peaks. Avoid declaring accelerator saturation from total GPU activity.
2. Prototype bounded batches of same-length Pyannote windows or a Core ML conversion. Compare against CPU probabilities and actual boundary decisions using speech, silence, music, overlap and short replies. Keep original default until both throughput and boundary accuracy pass. Explicitly measure cpuAndNeuralEngine versus all placement rather than assuming ANE is fastest.
3. Prototype Qwen audio encoder batching behind an opt-in flag, capped by memory and preserving independent cue boundaries/cancellation. Current upstream streaming API serializes encoder+decode; this needs an upstream API extension or maintained adapter, not concurrent unsynchronized tasks using one model.
4. Migrate the subtitle TextEditor only after demonstrating IME marked text, selected substring split/replace, focus and single-source undo parity. Keep AVPlayerView until VideoPlayer's fullscreen/control behavior is verified. AppKit file panels, security-scoped access, clipboard and application lifecycle APIs do not benefit from cosmetic wrappers.

No dependency upgrade, new custom Metal kernel, Core ML weight conversion, precision change or engine-default change was made in this iteration.
