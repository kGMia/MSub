# MSub 语音模型与 Apple 原生推理路线

核查日期：2026-09-12。结论：保留 FireRedASR2-AED MLX 默认引擎；Core AI 值得做独立实验，但目前不能直接替换本项目运行时。本文是源码和上游资料核查，未进行候选模型的本机准确率、速度或功耗对比。

## 本地实际状态

- 系统为 macOS 26.7，Xcode 26.6，项目最低 macOS 26。
- Python 默认 `mlx-community/FireRedASR2-AED-mlx`；已有本地权重。
- 已有 SenseVoiceSmall、MiMo-V2.5-ASR-MLX-4bit、Mega-ASR-bf16、Qwen3-ASR-1.7B-8bit、Fun-ASR-Nano-2512 的引擎实现和本地模型目录。继续添加同名选项没有意义。
- 原生 `AppleSpeechService` 已使用 SpeechAnalyzer / SpeechTranscriber。
- 本地已有 FireRedVAD-CoreML 和 speaker-diarization-coreml。VAD、说话人分析与 ASR 是不同环节；前两者使用 Core ML 不代表 ASR 已原生化。

## 新版本与候选

| 路线 | 已核实的信息 | 对 MSub 的判断 |
| --- | --- | --- |
| FireRedASR2-AED → FireRedASR2-LLM | 官方 2026-02-25 发布 LLM 权重；同一官方评测普通话平均 CER 为 AED 3.05%、LLM 2.89%，不同测试集并非都改善 | 是更晚发布的同代变体，不是已验证可直接加载的 MLX 升级包；收益需权衡运行成本 |
| Qwen3-ASR-1.7B MLX | 官方开放 0.6B/1.7B 和单独 ForcedAligner；项目已接入 1.7B 8bit | 多语言首选比较对象；不需要新增相同引擎 |
| Qwen-Audio-3.0-ASR | 2026-09-07 技术报告；项目页提供 Flash、Filetrans、Streaming 的云服务入口 | 本次未找到可直接替换本地 Qwen3-ASR 的开放权重或 MLX/Core AI 导出；作为云端候选观察 |
| Qwen3-ASR-0.6B Core ML | FluidInference 转换模型卡提供约 0.7GB int8 版本；报告 LibriSpeech WER 4.4%，并列出原 PyTorch 的 2.11%；AISHELL 仅抽样 100 文件 | 转换存在精度风险，且与现有 1.7B 不同规模；不能用“Core ML”标签推断更快、更准 |
| SenseVoice / Paraformer Core ML | FluidAudio 当前文档列出 SenseVoiceManager 和 ParaformerManager | 中文原生推理实验优先候选；SenseVoice 可与现有 MLX 路径对照；必须补齐分段、时间戳与取消语义 |
| Parakeet TDT v3 Core ML | FluidAudio 列为 25 种欧洲语言批处理模型 | 可用于英语等材料，不适合作为中文默认替代 |

来源：[FireRed 官方](https://github.com/FireRedTeam/FireRedASR2S)、[Qwen3 官方](https://github.com/QwenLM/Qwen3-ASR)、[Qwen-Audio-3.0 项目](https://qwenaudio.github.io/qwen-audio-3.0-asr/)、[技术报告](https://arxiv.org/abs/2609.07549)、[Qwen Core ML 模型卡](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml)、[FluidAudio 支持目录](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)。上游测试结果不能当作本项目实测，尤其不能跨数据集、量化精度和硬件直接排名。

## Core AI 与 Core ML 的区别

Core AI 是 Apple 新的独立框架，使用 `.aimodel`，提供模型特化、缓存、状态管理及 CPU/GPU/Neural Engine 推理。官方运行和集成要求 macOS/iOS 27+、Xcode 27+；当前文档仍标记 Beta。它不是 FireRed 的新一代识别权重，也不是把 `.mlpackage` 改扩展名即可使用的接口。[Apple 文档](https://developer.apple.com/documentation/coreai)、[官方运行要求](https://github.com/apple/coreai-models#requirements-running-and-app-integration)。

Apple 的模型目录已提供 Whisper、Parakeet、wav2vec2 导出路线；本次检查没有发现 FireRedASR2 或 Qwen3-ASR 条目，目录中的 Qwen3 是语言模型，不能视为 Qwen3-ASR。[官方模型目录](https://github.com/apple/coreai-models/tree/main/models)。Whisper 导出支持 large-v3 和 large-v3-turbo，是以后验证 Core AI ASR 的明确起点。[Whisper 导出说明](https://github.com/apple/coreai-models/tree/main/models/whisper)。

Core ML 仍可运行现有 `.mlpackage` / `.mlmodelc`；计算设备选择允许系统使用 CPU/GPU/ANE，不保证整个模型都运行在 ANE，也不保证转换后优于 MLX。[计算设备说明](https://developer.apple.com/documentation/coreml/mlcomputeunits)。

## 建议实施顺序

1. 保持 FireRed 默认，先用同一批有人工文字和时间边界标注的中文、粤语、中英混合、噪声和纯静音素材比较已安装的 FireRed/Qwen3/SenseVoice。分别记录 CER/WER、幻觉、漏字、边界偏差、冷启动、热运行耗时和峰值内存。
2. 若目标是减少 Python 打包负担，在 macOS 26 上先验证已有 Apple Speech 路径，再将 SenseVoice Core ML 做成可选原生引擎。分段继续依赖识别前 VAD，不靠识别后整体平移掩盖时间边界错误。
3. 升级测试环境至 macOS/Xcode 27 后，用 Whisper large-v3-turbo 验证 Core AI 的导出、Swift 解码、时间戳、长文件分段与打包。通过版本可用性检查保留 macOS 26 路径。
4. 只有候选在真实字幕素材上达到准确率与时间边界要求，且性能收益明确，才调整默认引擎。本次未改默认模型、下载候选权重或升级依赖。

## 本次相关修复

Apple Speech 原来在请求语言不支持时选择 `supportedLocales.first`，可能用另一种语言继续识别；现在只接受系统判定的等价语言，否则返回已有本地化错误。结果流错误不再被吞掉；取消和失败会结束 analyzer 并回收结果任务，成功前再次检查取消状态。编译与现有测试用于验证集成，真实 Speech 识别和处理中取消仍需端到端验收。
