# MSub

[English](README.md) | [簡體中文](README.zh-CN.md) | [發佈頁面](https://github.com/kGMia/MSub/releases)

MSub 是一款面向 Apple Silicon Mac 的原生字幕工具。它可以把本機影片或音訊轉換成可編輯字幕，並使用 MLX 語音辨識模型在本機執行。

![MSub 介面截圖](screenshot.png)

## 主要功能

- 從本機媒體產生 SRT、VTT、ASS、TXT 或 JSON 字幕。
- 辨識前預覽語音分段。
- 使用原生 macOS 介面編輯字幕區塊。
- 在波形時間軸上調整字幕時間。
- 依序處理多個檔案。
- 將字幕儲存到原媒體檔案所在目錄。
- 可選說話者標籤、情緒標籤和翻譯功能。
- 支援 CLI 和 `msub://`，方便自動化工具或 AI agent 控制。
- 可選原生 Qwen3 MLX / FireRedVAD Core ML，以及各處理階段的耗時詳情。
- 雙語樣式、播放位置拆分、批次編輯、品質問題導覽與頂部「檔案」選單中的草稿復原。

近期實作與驗證範圍見 [階段記錄](MILESTONE_2026-10-10.md)，模型版本核查見 [模型更新](MODEL_UPDATE_2026-10-10.md)（簡體中文）。

## 系統需求

- Apple Silicon Mac。
- 目前原生 app 目標為 macOS 27 或更新版本。
- FireRedASR2 等後端引擎及原生失敗回退需要 Python 3.10-3.13；設定齊全的原生流程可不啟動 Python。
- 需要 `uv` 管理 Python 依賴。
- 需要 `ffmpeg` 擷取音訊。
- 需要預留數 GB 空間存放語音模型。

## 安裝

請從 [GitHub Releases](https://github.com/kGMia/MSub/releases) 下載打包版本，或在本機從原始碼建置。

目前建置為 ad-hoc 簽名，尚未經過 Apple 公證。如果 macOS 提示無法驗證開發者，請在 Finder 中按住 Control 點按 `MSub.app`，選擇「打開」並確認。

## 從原始碼建置

這個倉庫是 macOS app 專案。開發和發佈打包時，Python 後端來自完整工作區；完整工作區需要包含 `src/huz_subtitle`、`pyproject.toml`、`uv.lock` 和 `apps/MSub`。

目前原始碼包含 macOS 27 SDK 適配，需要 Xcode 27 和 macOS 27。原生 MLX 推理建議透過 Xcode 專案建置以產生 Metal 函式庫，單獨 `swift run` 不會編譯所需的 Metal 資源。首次建置需信任已鎖定的 Swift package 外掛 / 巨集，保留專案的 Metal 相容 Pre-action。SwiftPM 建置須先解析依賴，再執行 `python3 Scripts/patch-mlx-metal.py .build/checkouts`。

從目前倉庫執行原生 app target：

```bash
git clone https://github.com/kGMia/MSub.git
cd MSub
env CLANG_MODULE_CACHE_PATH=.swift-module-cache swift run
```

如果原始碼建置需要轉寫功能，請指定後端工作區：

```bash
MSUB_WORKSPACE=/path/to/full/workspace \
env CLANG_MODULE_CACHE_PATH=.swift-module-cache swift run
```

從完整工作區建置本機 app：

```bash
cd /path/to/full/workspace
MSUB_SIGNING_MODE=adhoc MSUB_INCLUDE_MODEL=0 apps/MSub/Scripts/build-release.sh
```

產生的 app 位於 `.xcode-derived-release/Build/Products/Release/MSub.app`。

## 命令列

建置後可以控制原生 app：

```bash
.build/debug/MSub --open /path/video.mp4 --transcribe
open 'msub://open?path=/path/video.mp4&preview=1'
open 'msub://stop'
```

後端工作區也提供直接產生字幕的命令：

```bash
UV_CACHE_DIR=.uv-cache uv run msub-srt input.mp4 --format srt
```

舊入口 `huz-srt` 和 `huz-web` 仍可使用；新用法建議使用 `msub-srt` 和 `msub-web`。

## 模型

MSub 可使用：

- FireRedASR2-AED MLX，預設 ASR 模型。
- SenseVoiceSmall MLX，適合多語言和豐富資訊辨識。
- MiMo-V2.5-ASR MLX 4-bit，適合中英文語音。
- FireRedVAD，用於語音活動偵測。
- pyannote.audio，可選說話者分離。
- ERes2NetV2 和 emotion2vec，可選說話者/情緒功能。

模型可以從 Hugging Face 下載，也可以放在本機 `models/` 目錄。

## 使用的開源專案

MSub 基於以下專案建構：

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

分發或商用前，請自行確認各模型和依賴的授權條款。

## 注意事項

- 後端和模型準備好後，轉寫在本機執行。
- 首次使用可能需要連網下載模型。
- 大型 ASR 模型下載需要時間。
- 字幕時間主要來自 VAD 語音分段，不是詞級時間戳。
- 說話者和情緒功能需要額外依賴與模型。
- app 會啟動本機後端服務，只監聽本機連接埠。

## 專案結構

- `Sources/MSub`：原生 macOS app 原始碼。
- `Scripts`：發佈、打包和驗證腳本。
- `MSub.xcodeproj`：Xcode 專案。
- `Package.swift`：本機建置用 Swift Package 設定。
- `RELEASE.md`：發佈建置說明。
