# MSub

[English](README.md)

MSub 是一款面向 Apple Silicon Mac 的本地字幕工具。它可以把视频或音频转换成可编辑字幕，并使用 MLX 语音识别模型在本机运行。

## 主要功能

- 从本地媒体生成 SRT、VTT、TXT 或 JSON 字幕。
- 识别前预览语音分段。
- 使用原生 macOS 界面编辑字幕块。
- 在波形时间轴上调整字幕时间。
- 按顺序处理多个文件。
- 将字幕保存到原媒体文件所在目录。
- 可选发言人标签、情绪标签和翻译功能。
- 支持 CLI 和 `msub://`，方便自动化工具或 AI agent 控制。

## 系统要求

- Apple Silicon Mac。
- 原生 app 目标为 macOS 26 或更新版本。
- 后端需要 Python 3.10-3.13。
- 需要 `uv` 管理 Python 依赖。
- 需要 `ffmpeg` 抽取音频。
- 需要预留数 GB 空间存放语音模型。

## 安装

目前还没有经过 Apple 公证的公开安装包。请先从源码运行或构建。

```bash
git clone https://github.com/kGMia/MSub.git
cd MSub
UV_CACHE_DIR=.uv-cache uv sync
```

运行原生 app：

```bash
cd apps/MSub
env CLANG_MODULE_CACHE_PATH=../../.swift-module-cache swift run
```

构建本地 `.app`：

```bash
MSUB_SIGNING_MODE=adhoc MSUB_INCLUDE_MODEL=0 apps/MSub/Scripts/build-release.sh
```

生成的 app 位于 `.xcode-derived-release/Build/Products/Release/MSub.app`。

如果 macOS 提示无法验证开发者，请在 Finder 中按住 Control 点按 `MSub.app`，选择“打开”并确认。这是本地 ad-hoc 签名构建的正常现象。

## 命令行

直接生成字幕：

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4
```

指定输出格式（`srt`、`vtt`、`ass`、`txt`、`json`）：

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --format ass
```

开启 `--align-words` 后，JSON 输出还会携带词级时间戳。

可选的质量增强（默认全部关闭）：

```bash
# 词级字幕时间（Qwen3 强制对齐器，MLX；支持中/英/日/韩）
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --align-words

# 中英文标点恢复（FireRedPunc，CPU；需要 uv sync --extra punc，Python 3.11+）
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --punctuate

# 嘈杂素材降噪（DeepFilterNet，MLX）
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --denoise

# Qwen3 系引擎（Mega-ASR）的热词/上下文提示
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --asr-engine mega --context "专有名词, 术语"
```

以上功能也可以通过 `MSUB_ALIGN_WORDS=1`、`MSUB_PUNCTUATE=1`、`MSUB_DENOISE=1` 等环境变量启用，原生 app 的后端同样生效；app 的识别设置和"设置 → 模型管理"页中有对应开关与模型下载入口。

控制原生 app：

```bash
apps/MSub/.build/debug/MSub --open /path/video.mp4 --transcribe
open 'msub://open?path=/path/video.mp4&preview=1'
open 'msub://stop'
```

旧入口 `huz-srt` 和 `huz-web` 仍可使用；新用法建议使用 `msub-srt` 和 `msub-web`。

## 模型

MSub 可使用：

- FireRedASR2-AED MLX，默认 ASR 模型。
- SenseVoiceSmall MLX，适合多语言和富信息识别。
- MiMo-V2.5-ASR MLX 4-bit，适合中英文语音。
- FireRedVAD，用于语音活动检测。
- pyannote.audio，可选发言人区分。
- ERes2NetV2 和 emotion2vec，可选发言人/情绪功能。
- Qwen3-ForcedAligner MLX，可选词级字幕时间（`--align-words`）。
- FireRedPunc，可选中英文标点恢复（`--punctuate`）。
- DeepFilterNet MLX，可选降噪预处理（`--denoise`）。

模型可以从 Hugging Face 下载，也可以放在本地 `models/` 目录。大型 ASR 模型通常有数 GB。

## 使用的开源项目

MSub 基于以下项目构建：

- [MLX](https://github.com/ml-explore/mlx)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [FireRedASR](https://github.com/FireRedTeam/FireRedASR)
- [FireRedVAD](https://github.com/FireRedTeam/FireRedVAD)
- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice)
- [MiMo-Audio](https://github.com/XiaomiMiMo/MiMo-Audio)
- [pyannote.audio](https://github.com/pyannote/pyannote-audio)
- [FFmpeg](https://ffmpeg.org/)
- [FastAPI](https://fastapi.tiangolo.com/) 和 [Uvicorn](https://www.uvicorn.org/)
- [uv](https://github.com/astral-sh/uv)

分发或商用前，请自行确认各模型和依赖的许可证。

## 注意事项

- 模型准备好后，转写在本机运行。
- 首次使用可能需要联网下载模型。
- 默认 FireRed ASR 模型体积较大，下载需要时间。
- 字幕时间主要来自 VAD 语音分段，不是词级时间戳。
- 发言人和情绪功能需要额外依赖与模型。
- app 会启动本地后端服务，只监听本机端口。

## 项目结构

- `apps/MSub`：原生 macOS app。
- `src/huz_subtitle`：Python 后端和 CLI。
- `models`：可选本地模型目录。
- `apps/MSub/RELEASE.md`：发行构建说明。
