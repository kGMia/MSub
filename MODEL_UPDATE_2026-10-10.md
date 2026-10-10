# 模型版本核查（2026-10-10）

结论：本次重点核查的四个 ASR / VAD 模型，本地 Hugging Face 下载记录的 revision 与实时模型 API 返回的远端 main 完全一致，未发现需要重新下载的版本。维持现有默认模型、量化精度和识别参数。

| 已安装模型 | 远端 main / 本地下载 revision | 远端最后修改时间（UTC） |
| --- | --- | --- |
| mlx-community/FireRedASR2-AED-mlx | `f3212eacfa49b851130b97c63653c8e06ee09bdb` | 2026-03-12 19:39:12 |
| mlx-community/Qwen3-ASR-1.7B-8bit | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | 2026-01-29 15:11:55 |
| aufklarer/Pyannote-Segmentation-MLX | `abef0110277063f0ea117a802832a3eba22af84c` | 2026-04-12 08:10:18 |
| illitan/FireRedVAD-CoreML | `df8717e73f307b61754253247c4dc0f0e3796d9f` | 2026-02-22 04:40:45 |

方法：读取 `https://huggingface.co/api/models/<repo>` 的 sha / lastModified，与本地各模型 `.cache/huggingface/download/**/*.metadata` 中的下载 revision 对照。不下载权重、不上传本地文件。此为版本溯源检查，不是对数 GB 权重的逐字节完整性校验；未对所有辅助模型做全面审计。

来源：[FireRed MLX 历史](https://huggingface.co/mlx-community/FireRedASR2-AED-mlx/commits/main)、[Qwen MLX 历史](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/commits/main)、[Pyannote MLX 历史](https://huggingface.co/aufklarer/Pyannote-Segmentation-MLX/commits/main)、[FireRedVAD Core ML 历史](https://huggingface.co/illitan/FireRedVAD-CoreML/commits/main)。部分网页索引较旧，表中时间以本次直接读取的 API 为准。

## 新版本与替代路线

- FireRed 官方仍提供 ASR2-AED 和 ASR2-LLM。LLM 是另一种推理架构，不是可直接替换当前 AED MLX 权重的补丁；本次没有发现官方发布更高代际的 AED 模型。[官方项目](https://github.com/FireRedTeam/FireRedASR2S)
- Qwen 官方在 2026-06-26 加入原生 Transformers 支持及 `-hf` 模型入口。这是另一种运行时集成方式，不能当作当前 MLX 8bit 模型必须更新的证据。[官方项目](https://github.com/QwenLM/Qwen3-ASR)
- Pyannote Community-1 是完整的说话人分离流程，与本项目用 segmentation-3.0 转换权重做 VAD 的路径不同；不是替换单个 VAD 权重即可升级的版本。[官方模型卡](https://huggingface.co/pyannote/speaker-diarization-community-1)
- Apple Core AI 目录列有 Whisper、Parakeet TDT、Wav2Vec2 等音频导出配方，本次未见 FireRedASR2 或 Qwen3-ASR；其中 Qwen3 条目为语言模型。可保留 Whisper 的独立实验计划，但不替换当前中文默认引擎。[官方模型目录](https://github.com/apple/coreai-models/tree/main/models)

## 运行库确有更新，单列后续升级

当前 Swift 锁文件是 mlx-swift **0.31.6**，mlx-audio-swift 固定在 **bf14ae0c26e4e85553dd989571cae29d70fa6735**。

- mlx-swift 最新 release **0.32.3**（2026-09-30）。发布说明包含低于 macOS / iOS 26.4 时的启动兼容修复。[发布说明](https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3)
- mlx-audio-swift 最新 release **v0.1.5**（2026-10-05），更新 mlx-swift / mlx-swift-lm 集成。[发布说明](https://github.com/Blaizzy/mlx-audio-swift/releases/tag/v0.1.5)

这两项是推理库更新，不等于新 ASR 权重。当前工程有针对锁定 MLX 源码的 Metal scalar Gather / constexpr 兼容修复，阶段收尾保留已编译验证的依赖组合。下一阶段先核对上游是否已修复这些问题，再升级完整依赖组、重新验证 Metal 故障样例和一段真实 Qwen 音频；不要只修改版本号或关闭 Metal validation。
