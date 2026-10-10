# macOS 27 SDK 适配

构建环境：Xcode 27.0 / macOS 27.0 SDK。Xcode 项目最低部署版本为 macOS 27；2026-10-10 收尾时将 Swift Package 和 CI 统一到 27。下文 macOS 26 的回退说明是初次适配记录，不代表当前应用支持在 26 上运行。

## 外观与交互

- 工具栏使用 SDK 的 `ToolbarItemVisibilityPriority`。在 macOS 27 上，转写按钮优先级高于一般操作，专注编辑按钮其次，后端状态使用低优先级；窗口变窄时由系统决定溢出布局。macOS 26 保留默认工具栏布局。
- 文件条统一使用应用内字符串拖动载荷，移除触发 `Unexpected identifier type. Expected UUID, got UUID` 崩溃的 `reorderContainer` 路径。
- 矩形玻璃面板集中通过 `msubPanel` 绘制：系统开启“降低透明度”或“增强对比度”时使用不透明系统背景和清晰边框；普通模式保留现有 Liquid Glass。此辅助功能改进也适用于 macOS 26。

## 功能

- 新增“专注编辑”：工具栏按钮或 `⌘⇧F` 隐藏设置栏及上方媒体信息区域，切换到字幕编辑页；退出后恢复原侧栏可见状态。此功能也适用于 macOS 26。
- 文件条拖动重排按文件 ID 保留选择与字幕状态。批处理、保存、翻译、视频裁剪、截图期间禁用重排；旧拖动回退路径也增加同样检查，避免异步任务使用的索引被移动。
- 现有 MLX、Apple Speech、翻译与 Python 回退路径保留；未引入自动模型下载或新的远程服务。

## 验证范围

按用户要求不执行完整测试。排序算法从生产源码直接执行了五项 Swift 断言，覆盖多项移动、追加、失效 ID、自身目标和失效目标，均通过；同样的回归案例已保存于 `FileQueueOrderTests.swift`。

用户可手动检查：缩窄窗口后的工具栏、拖动文件条、专注模式进入/退出，以及系统辅助功能显示设置切换。macOS 26 回退路径仅做编译检查，未进行系统运行验证。

## 依据

- [Apple：SwiftUI 新功能](https://developer.apple.com/swiftui/whats-new/)
- 本机 `MacOSX27.0.sdk` 的 SwiftUI / SwiftUICore 公共 `.swiftinterface`：具体签名与 macOS 可用性以安装 SDK 为准。例如 `toolbarOverflowMenu` 不支持 macOS，未用于本次适配。

最终构建通过：`/tmp/msub-sdk27-build.log`，使用用户常用 DerivedData；新 API 和 macOS 26 回退分支均已编译。

## 2026-09-16 修复

- 波形与原生音频导出迁移到 AVAssetReader Provider、`start()` 和异步 `next()`，移除八处废弃接口调用。导出逐块复制 PCM 数据后在 actor 内写入，避免借用闭包跨隔离域捕获可变音频状态。
- 通过 Xcode Validate Settings 应用资源符号扩展和默认符号剥离设置；保留 MLX 使用的 arm64 架构限定。

本次最终 Xcode 构建通过，日志 `/tmp/msub-reader27-final.log` 无 warning/error 诊断。基于生产导出器与现有测试场景的独立 Swift 6 冒烟检查通过：双声道重采样、裁剪时间、尾部限幅、取消操作。未执行完整测试；拖动交互待用户复核。

## 波形与交互优化（2026-09-16）

- 波形扫描直接借用连续 PCM 块，仅非连续块复制；使用非对齐 Float 读取，保持原有稀疏采样与峰值归一化规则。无效或溢出的时长返回空波形，避免整数转换崩溃。
- 文件拖动回调显式使用 `@MainActor @Sendable`，删除绕过并发检查的包装。
- 文件条悬停、重排、宽度变化和拖放高亮动画遵循“减少动态效果”；关闭相关符号动画及拖放缩放。
- 新旧波形在 300、1000、16000 点输出逐点一致。新增波形脉冲边界及缓存降采样测试；独立 Swift 6 检查器运行该场景及两项既有音频导出场景通过，未运行完整 XCTest 套件。
- Xcode 构建通过：`/tmp/msub-waveform-opt.log`，无 warning/error 诊断。未测量整体加载提速比例；UI 动画和拖动体验待手动检查。
