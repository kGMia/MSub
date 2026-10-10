# Swift MLX 迁移与后端工作流

## 当前实现

Qwen3-ASR 增加默认关闭的「Swift MLX」实验开关，适用于主界面的逐文件转写流程。继续使用已安装的本地 Qwen3-ASR 权重；不自动下载模型，也不改变 FireRedASR2 默认引擎。单条字幕重新识别也支持原生 Qwen：AVFoundation 将不超过 30 秒的片段转换为 16 kHz 单声道后交给 Swift MLX，只替换字幕文字、保留原时间范围；不支持的参数、过长片段或执行失败回退 Python。Apple Speech 单条重识别也不再预先启动 Python 后端。

流程为：Python 提取音频与 VAD → 复用同一份 16 kHz 单声道预览 WAV → Swift 逐段执行 Qwen3-ASR → 使用 VAD 原始采样边界生成字幕。裁剪片段的起始偏移会恢复到原视频时间轴。静音不加载模型；一次只读取不超过 30 秒的音频，避免把长媒体全部复制进 Swift 内存。

第一版仅支持贪心解码（temperature=0、top_p=1、top_k=0）。启用词级对齐、标点恢复、降噪、说话人、富信息或置信度过滤时继续使用 Python 完整管线。原生模型加载或执行失败会显示原因并回退 Python；取消不会触发回退。暂停在段间生效；取消会等待当前片段解码收尾，然后丢弃结果，不再开始下一段。上游流式取消不提供 GPU 生产任务的 join，因此不能在取消订阅后立即释放或复用模型。原生路径没有新增词级时间戳。

Swift 模型在一批文件间复用，批处理结束释放。原生加载前请求后端释放空闲模型，降低两份 ASR 权重同时驻留的概率；后端仍有活跃任务时拒绝卸载。加载期间通过临时符号链接目录处理上游 tokenizer 缓存写入，保留模型源目录。

## 后端调整

- 预览和转写共用可取消的模型任务槽；排队取消每 100 ms 检查一次，无需等待正在运行的识别完成。
- 预览也计入模型活动计数，缓存检查与卸载在同一把锁内执行，避免清理仍被使用的辅助模型。
- 兼容同步预览接口将重计算移出 ASGI 事件循环，使健康检查、进度与取消接口能继续响应。
- 新增仅供本机使用的预览音频读取接口，校验预览 ID、固定 WAV 路径和解析后的目录边界，包括符号链接逃逸。

## 构建与验证

Swift 依赖锁定至 `mlx-audio-swift` revision `bf14ae0c26e4e85553dd989571cae29d70fa6735`，SwiftPM 与 Xcode 均保存依赖锁。Xcode 构建需要单独安装 Metal Toolchain；仅 `swift test` 通过不代表 GPU 推理可用。调用 MLX 前检查 Metal 设备和可加载的着色器资源，以便缺失时返回 Python。

普通回归测试不加载大模型。真实推理测试显式启用：

```bash
cd apps/MSub
bash Scripts/test-native-mlx.sh /absolute/path/to/Qwen3-ASR-model /absolute/path/to/speech.wav
```

WAV 必须为 16 kHz 单声道、至少 5 秒，前 5 秒包含中文语音。脚本先构建 Xcode 着色器、运行 Swift 测试，再执行真实模型测试，检查非空字幕及裁剪偏移。它不证明识别质量、性能优势或长音频稳定性；这些需要带人工转写与语音边界的测试集。脚本不会自动安装工具链或下载权重。

2026-09-13 验证状态：Metal Toolchain 17F109 已安装；最终 Xcode 构建通过。Swift 普通回归 23 项，其中 22 项通过、1 项真实模型测试默认跳过；显式运行真实模型测试通过，覆盖非空中文字幕、12 秒偏移、同模型连续复用、解码中取消以及取消后再次识别。Python 普通测试 59 项通过、1 项 GPU 测试默认跳过；显式 GPU 测试 4 项通过。

应用内已确认包内 Python 启动和连接正常；修复了先找到外层开发仓库、继而在沙盒内错误调用外部 uv 的问题。显式 MSUB_WORKSPACE/HUZ_WORKSPACE 开发覆盖仍然优先。完整视频预览已启动，但 Mac 锁定中断了界面操作，应用内的最终字幕显示、暂停/恢复、裁剪预览复用和多文件 UI 验证尚未完成。模型服务层测试不能替代这些界面验证。与 Python 同权重的完整字幕质量和内存对比也尚未完成。

保持实验开关默认关闭。FireRed Swift 移植、原生标点及说话人向量暂未实施。

## 参考

- [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift/tree/bf14ae0c26e4e85553dd989571cae29d70fa6735)：本次 Qwen 模型加载和流式生成 API 的直接来源。
- [MLX Swift](https://github.com/ml-explore/mlx-swift)：Xcode Metal 资源构建与 Apple Silicon 推理运行时。
- [WhisperX](https://github.com/m-bain/whisperX)：参考先 VAD、后识别、独立对齐及分阶段释放模型的流程设计；未引入其 CUDA 依赖，也未沿用其性能数据。

本次为执行运行时迁移，不构成「Qwen 比 FireRed 更准确」的结论。Core AI 的系统要求和其他模型候选见 `MODEL_RESEARCH_2026-09-12.md`。

## 可选 Pyannote MLX 计算路径

原有 Pyannote 路径使用 NumPy 计算，名称中的 MLX 指转换后的权重。新增 `src/huz_subtitle/pyannote_mlx.py` 实现卷积、归一化、四层双向 LSTM 和分类器的实际 MLX 执行；循环层按固定窗口编译并逐层求值，限制惰性计算图的规模。

默认仍使用 NumPy。显式启用需在启动 Python 进程前同时设置：

```bash
MLX_ENABLE_TF32=0 MSUB_PYANNOTE_MLX_BACKEND=mlx UV_CACHE_DIR=.uv-cache \
  uv run msub-srt test.mp4 --preview-segments --vad-engine pyannote_mlx
```

`MSUB_PYANNOTE_MLX_BACKEND` 支持 `numpy`（默认）、`mlx` 和 `auto`。`auto` 仅在存在 Metal 且已关闭 TF32 时使用 MLX，否则保留 NumPy。TF32 是 MLX 的进程级设置：不能在已有模型运行后可靠地临时切换，也可能影响同一进程内其他模型的速度，因此不修改全局默认环境。

本机固定 10 秒窗口对照（5 秒测试语音加零填充）：严格 FP32 的最大概率差约 `6.56e-7`，0.5 阈值判断一致。NumPy 约 0.103 秒；MLX 首次调用约 0.274 秒，后续三次约 0.080/0.070/0.062 秒。这是单窗口测量，不是端到端性能或识别质量基准。开启默认 TF32 的原型曾出现约 0.002 概率差，未作为验证通过的配置发布。

完整 `test.mp4` 的 NumPy 与严格 FP32 MLX 预览均输出 16 段，时间边界和元数据完全一致。复现命令：

```bash
MLX_ENABLE_TF32=0 UV_CACHE_DIR=.uv-cache uv run python scripts/benchmark-pyannote-mlx.py /absolute/speech.wav
MLX_ENABLE_TF32=0 MSUB_TEST_MLX_AUDIO=/absolute/speech.wav UV_CACHE_DIR=.uv-cache \
  uv run python -m pytest tests/test_pyannote_mlx.py -q
```

## Xcode 编辑器提示与手动验收

若出现 `MLXHuggingFaceMacros ... must be enabled ... editor functionality`，这是依赖宏在当前 Xcode 中尚未启用的提示。本机已检查宏实现，并在问题导航器点击该提示、选择 `Trust & Enable`；处理后问题数为 0，Xcode 构建成功。该信任状态不随仓库提交传播，换机器或依赖版本变化后可能需要重新确认。无需修改依赖源文件或关闭全局宏校验。

按用户最新要求，其余界面验证交由用户完成，不再以锁屏作为当前阻塞：重点检查最终字幕与声音同步、暂停/恢复/取消、裁剪后预览复用及多文件处理。测试实例的原生 Qwen 开关此前已打开，代码默认仍为关闭；体验后可自行切回。

## 2026-09-14：并发修复与增量打包

Swift 6 的 `sending` 报错已修复：用于等待当前片段解码结束的 Task 只捕获 actor 和 Sendable 参数，MLX 模型与数组留在 actor 隔离范围内。仍保留取消后等待当前片段收尾的策略。

打包脚本新增独立 Python 运行时缓存。仅修改后端源码时更新源码，复用已经裁剪、签名的 Python 和依赖；依赖、运行时、打包配置或脚本变化会重建缓存。目录指纹由单个 Python 进程遍历，跳过字节码和常见缓存目录，避免为每个模型文件启动 stat 进程。需要强制刷新时设置 `MSUB_FORCE_PACKAGE_BACKEND=1`。

本机检查：Xcode 构建通过；Swift 普通测试 23 项（1 项显式模型测试默认跳过），0 失败；显式 Qwen 测试通过，包括新增 44.1 kHz 双声道 M4A 转换识别。指纹测试 2 项通过。实际源码增量打包约 0.69 秒，恢复源码约 0.60 秒，完全无变化约 0.56 秒；这是已有运行时缓存下的后端打包步骤，不代表首次打包或整次 Xcode 构建耗时。

界面手动检查交给用户：开启 Qwen Swift MLX 后选中一条字幕重新识别，确认文字更新、原时间范围保留及撤销可用。主流程的音频提取/VAD 和高级辅助处理仍使用 Python。

### 同日补充：回调并发与分段性能

AVAudioConverter 输入回调改用受锁保护的单次 buffer 持有器，避免捕获可变局部变量及非 Sendable 的 AVAudioPCMBuffer；真实双声道 M4A 转换识别测试通过。加载指示器改用固定尺寸 SwiftUI 圆环，避免 AppKit spinner 在布局动画中的尺寸舍入问题，界面日志待用户复核。

Pyannote NumPy LSTM 的输入投影改为整窗矩阵计算；63 秒样本保持 16 段、最大概率差 4.77e-7。FireRed Core ML 新增逐批进度回调。预览任务日志新增 `vad_runtime` 配置及 `preview_phase=audioPreparation/vad/audioEvents` 耗时，任务状态也包含 `phaseTimings`。

用户报告的一分钟音频检测超过 30 秒尚未在本地复现，不能认定回归根因已解决。更新应用后只需重跑原来的慢视频，若仍慢，可依据上述阶段日志继续定位。未改变 VAD 阈值、窗口重叠、默认计算后端或默认识别模型。

## 原生 PCM 音频准备（2026-09-14）

新增 `NativeAudioExporter`，通过 AVAssetReader 按缓冲块直接输出 16 kHz 单声道 PCM WAV。先在原媒体上裁剪，避免为了几秒字幕先转换整个不兼容媒体；不再先做一次 AAC 编码。裁剪转写和单条字幕重识别优先使用此路径，失败时保留原来的 M4A/ffmpeg 兼容处理。主流程的完整媒体 VAD 仍由 Python 执行。

导出按样本时间戳恢复相对于裁剪起点的位置：保留音轨前导空隙、填充时间戳间隙并丢弃重叠预卷样本；尾端限制在素材时长内。缓冲区固定为 16384 帧，逐块检查取消，失败或取消删除临时文件。

原生 Qwen 对现成 16 kHz 单声道文件直接读取；Python 音频准备对 PCM16 单声道目标采样率 WAV 分块复制，跳过 ffmpeg。自定义音频同步滤镜仍执行原转换流程。两处均避免重复重采样；不修改 VAD 阈值或分段策略。

合成音频检查覆盖 44.1 kHz 双声道转 16 kHz、裁剪后脉冲位置、尾端裁剪及预取消；Python 检查覆盖样本逐字节一致、进度、取消清理与不匹配格式回退。63 秒 PCM 文件的本机单次准备步骤：ffmpeg 约 0.0555 秒，直接复用约 0.0006 秒，仅反映这一处理步骤。

## MLX Metal 编译兼容（2026-09-15）

上游 mlx-swift 的 [issue #342](https://github.com/ml-explore/mlx-swift/issues/342) 与本地四条 `Constexpr if is a C++17 extension` 警告一致；原日志实际构建成功。MSub 的 C++20 设置不能改变 SwiftPM 依赖资源使用的 Metal 方言。

共享 scheme 构建前运行 `Scripts/patch-mlx-metal.py`，对固定依赖的两份生成头文件局部应用 `-Wc++17-extensions` diagnostic push/pop，保留编译期分支和其他警告。脚本核对原文件 SHA-256，重复应用不改变 mtime；依赖内容变化时跳过并提示重新审查。它会修改 DerivedData 内的依赖工作副本，不修改模型或依赖版本。上游修复后应删除此兼容补丁。自定义 SourcePackages 目录可手动作为脚本参数传入。

本机 Xcode 已变为 27.0（27A266a）；本次验证最初因缺少对应 Metal Toolchain 中止，不能将其误归于 constexpr 警告。工具链安装日志：`/tmp/msub-metal27-install.log`。

最终验证：对应 Metal Toolchain 27A266a 已安装，受影响内核重新编译后四条警告均未出现。另将 Xcode 27 类型检查超时的字幕编辑器修饰链拆为独立视图片段，保留原有行为。用户常用 DerivedData 的完整构建通过，日志 `/tmp/msub-metal-compat-final3.log`。

## 完整媒体原生准备与预览复用（2026-09-28）

原生 Qwen 流程的完整媒体现在优先使用 NativeAudioExporter，16 kHz 单声道 PCM16 WAV 直接复用；不支持的媒体回退原上传路径。已有预览时跳过原媒体重新解码，直接读取预览 PCM。原生失败后如需回退 Python，仍准备正确的裁剪输入并恢复时间偏移。

识别语言、ITN 与 SenseVoice 富信息不参与 Swift 预览失效判断；Python 预览签名同步排除语言和 ITN。VAD、模型、音频事件参数仍参与签名。Python 单项签名回归通过。FireRedVAD 的 Kaldi 特征与后处理尚未迁移到 Swift，本轮不改变语音边界规则。


## 原生 FireRedVAD（2026-09-29）

新增默认关闭的「原生 FireRedVAD（实验性）」开关。启用原生 Qwen3 后可见；需安装 Qwen3 和 FireRedVAD 本地模型，采用 VAD / FireRedVAD 分段，关闭音频事件过滤，并使用原生 Qwen 支持的识别参数。最长分段支持 0.1–30 秒；不支持的参数和自定义后端环境覆盖继续使用 Python。新转写任务没有可复用预览时，音频准备、语音检测和 Qwen 识别可在原生侧衔接，省去这条路径上的音频上传与预览 PCM 下载。配置与其他任务仍依赖本地后端。

`NativeFireRedVAD.swift` 使用 Accelerate 实现 400 点 Povey 窗、160 点帧移、512 点 FFT、80 维 Kaldi log-mel 和模型 CMVN；Core ML 每批最多 512 帧，复用八组状态缓存。每个文件重置神经网络状态，同一模型保持加载。顺序读取保留 240 个重叠样本，并补足 AVAudioFile 的短读取，避免漏帧。分段状态机、填充、低概率切分和短段合并遵循现有 Python 规则，计算和后处理均在 actor 中执行。支持分批进度、暂停检查和取消；检测失败回退 Python，取消不会触发回退。

参考算法：[kaldi-native-fbank feature-window.cc](https://github.com/csukuangfj/kaldi-native-fbank/blob/master/kaldi-native-fbank/csrc/feature-window.cc)、[mel-computations.cc](https://github.com/csukuangfj/kaldi-native-fbank/blob/master/kaldi-native-fbank/csrc/mel-computations.cc)（Apache-2.0）。模型输入以本地 FireRedVAD-CoreML README 为准。

针对性验证：12 秒真实音频得到 1,198 帧概率，原生与 Python 的最大概率差约 `3.24e-6`，0.4 阈值判断一致。15 组最终分段边界完全一致，覆盖真实概率、静音、持续语音、交替语音及三组参数。特征对比只覆盖诊断读取器返回的前 1,188 帧，最大差约 `2.74e-4`；不将它描述为全文件特征验证。边界、非法参数和损坏 CMVN 的三组回归主体以独立断言运行通过；未跑完整 XCTest。Xcode 最终增量编译通过，无 warning/error，日志 `/tmp/msub-native-vad-final2.log`。打包脚本缓存命中耗时 1 秒，不代表整次构建或转写耗时。

手动体验时，开启两个原生开关、选择 FireRedVAD，并对刚添加的文件直接开始转写。已有预览仍会复用；「预览分段」按钮仍使用后端。第一次使用需编译 Core ML 模型，后续文件复用加载结果。请重点检查字幕与语音同步、裁剪偏移、暂停和取消；尚未验证长媒体性能和端到端速度提升。


## 原生 Qwen 的 Metal 断言修复（2026-09-29）

在 Metal API Validation 开启时，固定版本 mlx-swift 的通用 Gather 对标量索引传入空的 shape/stride 元数据，触发 `bytes argument cannot be nil` 并直接 abort。独立小进程使用第二轴标量 take 复现相同断言（第一轴连续切片会走优化分支，不能覆盖此问题）。这不是 Swift 可捕获错误，也无法靠现有 Python 回退恢复已中止的进程。

构建前兼容脚本现为标量元数据绑定提供零占位，沿用该版本 Scatter 的做法；保留 Metal 校验及所有索引语义。补丁核对完整源码 SHA-256，重复执行不改变 mtime，源代码变化时明确报错要求复核。无需关闭 Metal API Validation 或修改模型。SwiftPM 单独构建时先执行 `swift package resolve`，再执行 `python3 Scripts/patch-mlx-metal.py .build/checkouts`。

增量 Xcode 构建通过，无 warning/error。以下两项针对性检查通过，未运行完整转写测试：

```bash
python3 -B Scripts/test-mlx-metal-patch.py
python3 -B Scripts/test-mlx-metal-gather.py /absolute/path/to/MSub-DerivedData
```

第二项直接链接该 Xcode 构建的 MLX 对象，并开启 Metal 校验，覆盖标量、向量、连续和转置数组索引。日志 `/tmp/msub-gather-after.log`。在 Xcode 中先停止已中止的调试运行，再重新 Build/Run，然后用原文件验证两个原生开关组合。

## 2026-09-29：复制前过滤 Python 打包内容

将 core 配置中不需要的依赖，以及精简模式下的测试、头文件、静态库和文档，提前在 rsync 复制阶段排除。保留原有 core/full、`MSUB_SLIM_VENV=0` 和强制刷新选项；`*.pyi`、公开的 `testing` 模块继续保留。排除规则集中在 `Scripts/package-runtime-filter.py` 并计入运行时缓存指纹；源码修改仍复用运行时缓存，规则或配置变化才刷新。失败刷新会先清除旧签名，避免误用半成品。

当前 `.venv` 的只读模拟中，空目标首次复制的候选数据从约 1.26 GB / 36,905 文件降到 381 MB / 8,117 文件；不含基础 Python 和模型，不代表完整构建耗时，也不代表最终包体积同比减少。下次构建因规则变化会刷新一次运行时。

验证仅运行 4 项真实 rsync/小型完整打包流程检查、2 项指纹检查和 shell 语法检查，未进行完整构建或模型测试。Xcode 仍调用脚本进行指纹检查，以覆盖新增/删除文件及环境选项变化。
