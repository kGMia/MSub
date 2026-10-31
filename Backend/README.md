# MSub

[中文说明](README.zh-CN.md)

MSub is a local subtitle app for Apple Silicon Macs. It turns video or audio files into editable subtitles using MLX speech-recognition models.

## Main Features

- Generate SRT, VTT, TXT, or JSON subtitles from local media.
- Preview speech segments before transcription.
- Edit subtitle blocks with a native macOS interface.
- Adjust timing on a waveform timeline.
- Process multiple files in order.
- Save subtitles beside the original media file.
- Optional speaker labels, emotion tags, and translation tools.
- CLI and `msub://` control support for automation and AI agents.

## Requirements

- Apple Silicon Mac.
- macOS 26 or newer for the native app target.
- Python 3.10-3.13 for the backend.
- `uv` for Python dependency management.
- `ffmpeg` for audio extraction.
- Several GB of free disk space for speech models.

## Install

There is not yet a notarized public installer. For now, build or run from source.

```bash
git clone https://github.com/kGMia/MSub.git
cd MSub
UV_CACHE_DIR=.uv-cache uv sync
```

Run the native app:

```bash
cd apps/MSub
env CLANG_MODULE_CACHE_PATH=../../.swift-module-cache swift run
```

Build a local `.app`:

```bash
MSUB_SIGNING_MODE=adhoc MSUB_INCLUDE_MODEL=0 apps/MSub/Scripts/build-release.sh
```

The app will be created under `.xcode-derived-release/Build/Products/Release/MSub.app`.

If macOS says the app cannot be verified, Control-click `MSub.app`, choose **Open**, then confirm. This is expected for ad-hoc signed local builds.

## Command Line

Generate subtitles directly:

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4
```

Choose an output format (`srt`, `vtt`, `ass`, `txt`, `json`):

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --format ass
```

With `--align-words`, JSON output also carries word-level timestamps per segment.

Bias recognition toward names and domain terms (Qwen3-based engines such as Mega-ASR):

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --asr-engine mega --context "MLX, Apple Silicon"
```

Optional quality refinements (all off by default):

```bash
# Word-level subtitle timing via forced alignment (Qwen3-ForcedAligner, MLX; zh/en/ja/ko)
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --align-words

# Punctuation restoration for zh/en (FireRedPunc, CPU; needs: uv sync --extra punc, Python 3.11+)
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --punctuate

# Denoise noisy recordings before recognition (DeepFilterNet, MLX)
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --denoise
```

Both can also be enabled with `MSUB_ALIGN_WORDS=1` / `MSUB_PUNCTUATE=1`, which the
native app's backend picks up as well. Models download from Hugging Face on first
use, or can be placed in `models/Qwen3-ForcedAligner-0.6B-8bit` and `models/FireRedPunc`.

Control the native app:

```bash
apps/MSub/.build/debug/MSub --open /path/video.mp4 --transcribe
open 'msub://open?path=/path/video.mp4&preview=1'
open 'msub://stop'
```

Legacy commands `huz-srt` and `huz-web` still work, but new usage should prefer `msub-srt` and `msub-web`.

## Models

MSub can use:

- FireRedASR2-AED MLX, the default ASR model.
- SenseVoiceSmall MLX, useful for multilingual speech and rich info.
- MiMo-V2.5-ASR MLX 4-bit, useful for Chinese/English speech.
- FireRedVAD, used for speech activity detection.
- pyannote.audio, optional speaker diarization.
- ERes2NetV2 and emotion2vec, optional speaker/emotion features.
- Qwen3-ForcedAligner MLX, optional word-level subtitle timing (`--align-words`).
- FireRedPunc, optional zh/en punctuation restoration (`--punctuate`).

Models may be downloaded from Hugging Face or placed in the local `models/` folder. Large ASR models can be several GB.

## Open Source Projects Used

MSub is built on top of:

- [MLX](https://github.com/ml-explore/mlx)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [FireRedASR](https://github.com/FireRedTeam/FireRedASR)
- [FireRedVAD](https://github.com/FireRedTeam/FireRedVAD)
- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice)
- [MiMo-Audio](https://github.com/XiaomiMiMo/MiMo-Audio)
- [pyannote.audio](https://github.com/pyannote/pyannote-audio)
- [FFmpeg](https://ffmpeg.org/)
- [FastAPI](https://fastapi.tiangolo.com/) and [Uvicorn](https://www.uvicorn.org/)
- [uv](https://github.com/astral-sh/uv)

Please check each model and dependency license before redistribution or commercial use.

## Notes

- Transcription runs locally after models are available.
- First use may need network access to download models.
- The default FireRed ASR model is large; downloads can take time.
- Subtitle timing is based on VAD speech segments, not word-level timestamps.
- Optional speaker and emotion features require extra dependencies and models.
- The local backend is started by the app and listens only on a local port.

## Project Layout

- `apps/MSub`: native macOS app.
- `src/huz_subtitle`: Python backend and CLI.
- `models`: optional local model folder.
- `apps/MSub/RELEASE.md`: release build notes.
