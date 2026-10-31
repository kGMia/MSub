# Progressive timing drift and native live preview — 2026-10-30

## Confirmed on supplied problem.mp4

Audio is AAC48 kHz,365468 packets, container endpoint7840.211 s. Nominal decoded1024-frame packet duration sums to7796.651 s (~43.56 s shorter). Packet duration/timestamp variation carries the media clock; summing decoded frames loses it. Merely padding the final WAV back to video duration hides this error.

Both the previous AVAssetReaderTrackOutput exporter and a trial AVAssetReaderAudioMixOutput export compressed this audio timeline despite writing blocks using the reader's PTS. Cross-correlation of20 s amplitude envelopes against FFmpeg timestamp-synchronized PCM:

| Reference position | Previous native audio offset | Fixed extraction offset |
|---|---:|---:|
|60 s|-0.32 s|0.00 s|
|1800 s|-9.58 s|0.00 s|
|3600 s|-19.50 s|0.00 s|
|7200 s|-39.16 s|0.00 s|

Offsets measured at10 ms resolution, not a claim of sample-perfect alignment or a complete ASR rerun. Input video unchanged. Fixed Swift exporter processed the whole audio in12.1 s; no full-video recognition was run.

## Fix

NativeAudioExporter checks track audio formats. Compressed/unknown formats use the existing managed FFmpeg process runner, synchronizing PTS with aresample=async=1000:first_pts=0 and writing mono16k PCM directly. A finite output-duration limit plus apad preserves trailing silence and clip duration. PCM inputs retain the native reader and its leading-gap/preroll handling. Cancellation uses the existing process registry/waiter and deletes incomplete output. This prioritizes correct timestamps for compressed inputs; no heuristic global stretch or guessed subtitle offset.

WaveformLoader uses the same synchronized PCM for compressed media, then downsamples normally. Its disk cache namespace is bumped to timeline-pcm-v4. Frontend preview reuse key bumped audio-sync-v4-packet-clock to invalidate stale prepared segments when next previewing/transcribing. Existing exported subtitles are not silently modified: rerun preview/transcription for those files.

## Live native Qwen subtitles

Native service previously reported only progress/diagnostics, returning all cues at the end. It now awaits an onCue callback after each nonempty completed segment, before final progress, preserving order and timeOffset. ContentView appends live text using stable file ID; final completion still installs the authoritative editable subtitle document. Partial preview is cleared before Python fallback to avoid mixing attempts. Cancel checks precede cue emission, and callback time is excluded from inference accounting. This is segment-completion streaming, not unstable per-token subtitle timing.

## Targeted validation

- Production exporter code in a standalone Swift6 harness compared full supplied-video PCM at four positions above. Trial AudioMixOutput did not fix the issue and was not adopted.
- Added NativeAudioExporterTests.testCompressedPacketClockDoesNotAccumulateDrift: synthetic60 s AAC with1% timestamp expansion and a40 s pulse; exact test body run with production exporter/runner passed. Verifies pulse stays on container time instead of decoded sample-count time.
- Actual NativeQwenService with JA BF16 weights and two5 s test.mp4 audio segments emitted two cue callbacks before final progress, preserving12 s offset; passed. Recorder did not print transcript. Persistent opt-in NativeQwenStreamingTests uses MSUB_TEST_QWEN_MODEL / MSUB_TEST_QWEN_AUDIO.
- Xcode BuildProject passed (9.443 s, no errors, log20261030-155840); git diff --check passed. No full suite or complete affected-video ASR run. Remaining user check: relaunch rebuilt app, regenerate affected subtitles, check later speech and live preview.
