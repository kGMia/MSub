# MSub 发布手册

现有工具链已覆盖签名、公证、DMG 打包与更新检查（App 内通过 GitHub Releases API 检查新版本）。本文按"现在就能做"与"需要 Apple 开发者账号"两部分整理。

## 现在就能做（无开发者账号）

### 1. 版本号

在 `MSub.xcodeproj` 两个构建配置中更新 `MARKETING_VERSION`（当前 0.1.0）与 `CURRENT_PROJECT_VERSION`。更新检查器比较的是 GitHub Release 的 tag，请保持 tag 与 `MARKETING_VERSION` 一致（如 `v0.2.0`）。

### 2. 发布前检查

```bash
UV_CACHE_DIR=.uv-cache uv run pytest tests/ -q          # 后端测试（仓库外）
swift build && swift test                                # App 构建与测试
Scripts/release-preflight.sh                             # 既有 preflight
```

### 3. Ad-hoc 构建（自用/测试分发）

```bash
MSUB_SIGNING_MODE=adhoc MSUB_INCLUDE_MODEL=0 Scripts/build-release.sh
Scripts/validate-release-bundle.sh
Scripts/package-dmg.sh
```

接收者需 Control-click → 打开 以绕过 Gatekeeper（README 已说明）。

### 4. GitHub Release

创建 tag + Release 并附上 DMG。App 的"检查更新"读取
`https://api.github.com/repos/kGMia/MSub/releases/latest`，发布即生效。

## 需要开发者账号后补齐

### 1. Developer ID 签名 + 公证

脚本已就绪（`Scripts/sign-notarize-release.sh`，含 hardened runtime 与逐个
Mach-O 签名），只需提供凭据：

```bash
export MSUB_DEVELOPER_ID_APPLICATION="Developer ID Application: <名字> (<TEAMID>)"
export MSUB_NOTARY_KEYCHAIN_PROFILE="msub-notary"   # 先用 notarytool store-credentials 建好
MSUB_SIGNING_MODE=automatic Scripts/build-release.sh   # 会自动调用签名+公证脚本
```

首次配置 notarytool 凭据：

```bash
xcrun notarytool store-credentials msub-notary \
  --apple-id <appleid> --team-id <TEAMID> --password <app专用密码>
```

### 2. 待办清单

- [ ] `MSub.xcodeproj` 填入 `DEVELOPMENT_TEAM`
- [ ] 用 Developer ID 走一遍完整 build → sign → notarize → staple → dmg
- [ ] 在干净的 macOS 上验证 Gatekeeper 直接放行
- [ ] （可选）接入 Sparkle 替代现有的"打开 Releases 页面"式更新

## 发布冒烟清单

- [ ] 转写一个中文视频（默认 FireRedASR2-AED）与一个英文视频
- [ ] 词级对齐 + 标点 + 降噪各开一次，确认失败时能回退不崩
- [ ] 设置 → 模型管理：下载一个小模型、删除、重新下载（断点续传）
- [ ] SRT/VTT/ASS/JSON 四种格式导出并重新打开编辑
- [ ] 大文件（>2GB）任务应秒级进入音频提取（本地路径直传生效）
- [ ] 断网状态下 App 仍可用本地模型转写
