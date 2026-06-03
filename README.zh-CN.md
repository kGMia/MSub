# MSub

[English](README.md)

MSub 是一款面向 Apple Silicon Mac 的原生字幕工具。它可以把本地视频或音频转换成可编辑字幕，并使用 MLX 语音识别模型在本机运行。

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
- 本地转写需要 Python 3.10-3.13 后端。
- 需要 `uv` 管理 Python 依赖。
- 需要 `ffmpeg` 抽取音频。
- 需要预留数 GB 空间存放语音模型。

## 安装

MSub 目前还没有经过 Apple 公证的公开安装包。请使用可信构建的 `MSub.app`，或在本地从源码构建。

如果 macOS 提示无法验证开发者，请在 Finder 中按住 Control 点按 `MSub.app`，选择“打开”并确认。这是本地 ad-hoc 签名构建的正常现象。

## 从源码构建

这个仓库是 macOS app 项目。开发和发行打包时，Python 后端来自完整工作区；完整工作区需要包含 `src/huz_subtitle`、`pyproject.toml`、`uv.lock` 和 `apps/MSub`。

从当前仓库运行原生 app target：

```bash
git clone https://github.com/kGMia/MSub.git
cd MSub
env CLANG_MODULE_CACHE_PATH=.swift-module-cache swift run
```

如果源码构建需要转写功能，请指定后端工作区：

```bash
MSUB_WORKSPACE=/path/to/full/workspace \
env CLANG_MODULE_CACHE_PATH=.swift-module-cache swift run
```

从完整工作区构建本地 app：

```bash
cd /path/to/full/workspace
MSUB_SIGNING_MODE=adhoc MSUB_INCLUDE_MODEL=0 apps/MSub/Scripts/build-release.sh
```

生成的 app 位于 `.xcode-derived-release/Build/Products/Release/MSub.app`。

## 命令行

构建后可以控制原生 app：

```bash
.build/debug/MSub --open /path/video.mp4 --transcribe
open 'msub://open?path=/path/video.mp4&preview=1'
open 'msub://stop'
```

后端工作区也提供直接生成字幕的命令：

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --format srt
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

模型可以从 Hugging Face 下载，也可以放在本地 `models/` 目录。

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

- 后端和模型准备好后，转写在本机运行。
- 首次使用可能需要联网下载模型。
- 大型 ASR 模型下载需要时间。
- 字幕时间主要来自 VAD 语音分段，不是词级时间戳。
- 发言人和情绪功能需要额外依赖与模型。
- app 会启动本地后端服务，只监听本机端口。

## 项目结构

- `Sources/MSub`：原生 macOS app 源码。
- `Scripts`：发行、打包和验证脚本。
- `MSub.xcodeproj`：Xcode 项目。
- `Package.swift`：本地构建用 Swift Package 配置。
- `RELEASE.md`：发行构建说明。
