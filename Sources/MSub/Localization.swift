import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh
    case en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zh: "中文"
        case .en: "English"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .zh: "zh-Hans"
        case .en: "en"
        }
    }

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }
}

enum Copy {
    /// Tries native bundle localization first (when `Localizable.xcstrings`/`.strings` is
    /// wired into the Xcode target), then falls back to the inline dictionary.
    static func text(_ key: String, language: AppLanguage) -> String {
        if let native = nativeLocalizedString(forKey: key, language: language) {
            return native
        }
        return strings[key]?[language] ?? strings[key]?[.en] ?? key
    }

    private static func nativeLocalizedString(forKey key: String, language: AppLanguage) -> String? {
        let identifier = language.localeIdentifier
        guard
            let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return nil
        }
        let missingSentinel = "__huz_missing__"
        let value = bundle.localizedString(forKey: key, value: missingSentinel, table: nil)
        return value == missingSentinel ? nil : value
    }

    private static let strings: [String: [AppLanguage: String]] = [
        "app.title": [.zh: "MSub", .en: "MSub"],
        "backend.start": [.zh: "启动后端", .en: "Start Backend"],
        "backend.stop": [.zh: "停止后端", .en: "Stop Backend"],
        "backend.check": [.zh: "检查连接", .en: "Check"],
        "backend.connected": [.zh: "后端已连接", .en: "Backend connected"],
        "backend.disconnected": [.zh: "后端未连接", .en: "Backend not connected"],
        "backend.running": [.zh: "后端运行中", .en: "Backend running"],
        "backend.stopped": [.zh: "后端已停止", .en: "Backend stopped"],
        "input.section": [.zh: "输入", .en: "Input"],
        "input.choose": [.zh: "选择媒体", .en: "Choose Media"],
        "input.drop": [.zh: "拖入视频或音频文件", .en: "Drop a video or audio file"],
        "input.none": [.zh: "尚未选择文件", .en: "No file selected"],
        "settings.output": [.zh: "输出", .en: "Output"],
        "settings.model": [.zh: "模型", .en: "Model"],
        "settings.format": [.zh: "格式", .en: "Format"],
        "settings.mode": [.zh: "分段模式", .en: "Mode"],
        "settings.language": [.zh: "界面语言", .en: "Language"],
        "settings.segmentation": [.zh: "语音分段", .en: "Segmentation"],
        "settings.recognition": [.zh: "识别", .en: "Recognition"],
        "settings.advanced": [.zh: "高级参数", .en: "Advanced"],
        "settings.preset": [.zh: "场景预设", .en: "Scene preset"],
        "settings.threshold": [.zh: "阈值 dB", .en: "Threshold dB"],
        "settings.maxSegment": [.zh: "最大分段", .en: "Max segment"],
        "settings.silence": [.zh: "静音间隔", .en: "Silence gap"],
        "settings.search": [.zh: "切点搜索", .en: "Cut search"],
        "settings.minSpeech": [.zh: "最短语音", .en: "Min speech"],
        "settings.padding": [.zh: "边界留白", .en: "Boundary pad"],
        "settings.minSegment": [.zh: "最短分段", .en: "Min segment"],
        "settings.fixedChunk": [.zh: "固定切片", .en: "Fixed chunk"],
        "settings.beam": [.zh: "Beam", .en: "Beam"],
        "settings.confidence": [.zh: "最低置信度", .en: "Min confidence"],
        "settings.lineChars": [.zh: "每行字数", .en: "Line chars"],
        "preset.balanced": [.zh: "平衡", .en: "Balanced"],
        "preset.dialogue": [.zh: "现场对话", .en: "Live dialogue"],
        "preset.lowVoice": [.zh: "低音量/低频", .en: "Low voice"],
        "preset.noisy": [.zh: "嘈杂环境", .en: "Noisy"],
        "preset.fastCut": [.zh: "短句快切", .en: "Fast cuts"],
        "preset.sensitive": [.zh: "更灵敏", .en: "Sensitive"],
        "preset.reset": [.zh: "重置", .en: "Reset"],
        "preset.apply": [.zh: "应用预设", .en: "Apply preset"],
        "preset.balanced.help": [.zh: "通用默认值。适合清晰录音、普通语速和多数视频。", .en: "General defaults for clear recordings, ordinary speaking pace, and most videos."],
        "preset.dialogue.help": [.zh: "更积极地按停顿切分，适合多人现场对话、访谈和会议片段。", .en: "Splits more actively around pauses, useful for live dialogue, interviews, and meetings."],
        "preset.lowVoice.help": [.zh: "降低能量阈值并增加边界留白，减少低音量、低频或离麦较远语音被漏掉的概率。", .en: "Lowers the energy threshold and adds boundary padding to catch quiet, low-frequency, or distant speech."],
        "preset.noisy.help": [.zh: "提高阈值并过滤更短噪声，适合背景声较强、键盘声或环境声明显的素材。", .en: "Raises the threshold and filters short noise bursts for loud background noise or keyboard/environment sounds."],
        "preset.fastCut.help": [.zh: "缩短最大分段和静音合并，适合短句、快节奏剪辑和需要更碎字幕的场景。", .en: "Shortens max segments and silence bridging for short utterances, fast edits, and finer subtitles."],
        "preset.sensitive.help": [.zh: "比平衡模式更容易捕获弱语音，但也可能多切出呼吸声或环境声。", .en: "Catches weaker speech than Balanced, with a higher chance of including breath or background sounds."],
        "action.preview": [.zh: "预览分段", .en: "Preview"],
        "action.transcribe": [.zh: "开始识别", .en: "Transcribe"],
        "action.save": [.zh: "保存结果", .en: "Save Result"],
        "action.saveAll": [.zh: "保存全部", .en: "Save All"],
        "action.copy": [.zh: "复制文本", .en: "Copy Text"],
        "action.stop": [.zh: "停止", .en: "Stop"],
        "file.remove": [.zh: "移除文件", .en: "Remove file"],
        "file.summary": [.zh: "已完成 %d/%d，失败 %d", .en: "%d/%d done, %d failed"],
        "segments.title": [.zh: "分段", .en: "Segments"],
        "segments.empty": [.zh: "先预览分段，时间轴会显示在这里。", .en: "Preview segments to populate the timeline."],
        "segments.noPreview": [.zh: "暂无预览", .en: "No preview"],
        "segments.count": [.zh: "个分段", .en: "segments"],
        "segments.avg": [.zh: "平均", .en: "Avg"],
        "segments.max": [.zh: "最长", .en: "Max"],
        "segments.speech": [.zh: "语音占比", .en: "Speech"],
        "output.title": [.zh: "字幕结果", .en: "Subtitle Output"],
        "output.placeholder": [.zh: "识别完成后，字幕预览会显示在这里。", .en: "Subtitle preview will appear here after transcription."],
        "status.ready": [.zh: "就绪", .en: "Ready"],
        "status.connected": [.zh: "已连接", .en: "Connected"],
        "status.detecting": [.zh: "正在检测语音分段", .en: "Detecting speech segments"],
        "status.previewReady": [.zh: "分段预览完成", .en: "Segment preview ready"],
        "status.previewFailed": [.zh: "分段预览失败", .en: "Segment preview failed"],
        "status.starting": [.zh: "正在创建识别任务", .en: "Starting job"],
        "status.loading": [.zh: "正在加载模型", .en: "Loading model"],
        "status.transcribing": [.zh: "正在识别", .en: "Transcribing"],
        "status.done": [.zh: "完成", .en: "Done"],
        "status.failed": [.zh: "识别失败", .en: "Transcription failed"],
        "status.saved": [.zh: "结果已保存", .en: "Result saved"],
        "status.savedAll": [.zh: "全部结果已保存", .en: "All results saved"],
        "status.saving": [.zh: "正在保存结果", .en: "Saving result"],
        "status.copied": [.zh: "已复制字幕文本", .en: "Copied subtitle text"],
        "status.cancelled": [.zh: "已取消", .en: "Cancelled"],
        "error.title": [.zh: "错误", .en: "Error"],
        "error.saveAllFailed": [.zh: "部分文件保存失败：%@", .en: "Some files failed to save: %@"],
        "button.ok": [.zh: "好", .en: "OK"],
        "help.model": [.zh: "Hugging Face 模型 ID 或本地模型目录。当前建议使用本地 FireRedASR2-AED-mlx 权重路径，避免联网下载。", .en: "Hugging Face model id or local model directory. Use the local FireRedASR2-AED-mlx path to avoid network downloads."],
        "help.format": [.zh: "SRT/VTT 用于字幕软件，TXT 用于纯文本稿，JSON 用于后续程序处理。", .en: "SRT/VTT are subtitle formats, TXT is a plain transcript, JSON is best for downstream tooling."],
        "help.mode": [.zh: "VAD 会按实际语音活动分段，通常更适合字幕同步；固定切片只作为回退方案。", .en: "VAD segments by detected speech activity and is usually better for subtitle sync; fixed chunks are a fallback."],
        "help.preset": [.zh: "一键调整下方分段和识别参数。预设只是起点，仍可继续手动微调。", .en: "Applies a starting point for segmentation and recognition settings. You can still fine-tune manually."],
        "help.threshold": [.zh: "语音能量阈值。数值越高越严格，噪声更少但可能漏掉轻声；数值越低越灵敏。", .en: "Speech energy threshold. Higher is stricter and reduces noise; lower catches quieter speech."],
        "help.maxSegment": [.zh: "单个识别分段允许的最长时间。越短字幕越碎、越贴近语音；过短可能损失上下文。", .en: "Maximum duration for one recognition segment. Shorter gives tighter subtitles; too short can lose context."],
        "help.silence": [.zh: "短于此值的静音会被合并到同一段。调小会切得更碎，调大会减少碎片。", .en: "Silences shorter than this are bridged. Lower values split more; higher values merge more."],
        "help.search": [.zh: "长分段切开时，在目标切点附近搜索最安静位置的范围。增大可找到更自然切点。", .en: "Search window around a long-segment cut point for the quietest frame. Larger can find more natural cuts."],
        "help.minSpeech": [.zh: "短于此值的语音活动会被视为噪声。嘈杂素材可调高，低音量语音可调低。", .en: "Detected speech shorter than this is treated as noise. Raise for noisy audio; lower for quiet speech."],
        "help.padding": [.zh: "给每段开头和结尾额外保留的时间。增加可避免吞字，减少可让字幕出现/消失更贴合语音。", .en: "Extra time before and after each segment. More avoids clipped words; less makes subtitles tighter."],
        "help.minSegment": [.zh: "切分后过短的小段会被合并。降低它会保留更多短字幕。", .en: "Tiny split remainders below this are merged. Lower it to keep more short subtitles."],
        "help.fixedChunk": [.zh: "固定切片模式下每段时长。VAD 模式下基本不影响结果。", .en: "Chunk length used by fixed mode. It mostly does not affect VAD mode."],
        "help.beam": [.zh: "模型解码搜索宽度。更大可能略稳但更慢；本地实时调试通常 3 或 4 足够。", .en: "Model decoding beam width. Larger can be steadier but slower; 3 or 4 is usually enough locally."],
        "help.confidence": [.zh: "丢弃低于此置信度的识别片段。模型不返回置信度时不会生效；嘈杂素材可略微调高。", .en: "Drops recognized pieces below this confidence. No effect if the model does not return confidence; raise slightly for noisy audio."],
        "help.lineChars": [.zh: "字幕换行宽度。中文通常 14-20 较舒服，设为 0 可关闭自动换行。", .en: "Subtitle line wrapping width. 14-20 works well for Chinese; set 0 to disable wrapping."],

        "tab.segments": [.zh: "分段", .en: "Segments"],
        "tab.output": [.zh: "字幕", .en: "Output"],
        "preview.title": [.zh: "预览", .en: "Preview"],
        "preview.show": [.zh: "显示预览", .en: "Show preview"],
        "preview.unsupported": [.zh: "此文件无法显示预览。", .en: "Preview not available for this file."],

        "prefs.title": [.zh: "偏好设置", .en: "Settings"],
        "prefs.general": [.zh: "通用", .en: "General"],
        "prefs.model": [.zh: "模型", .en: "Model"],
        "prefs.appearance": [.zh: "外观", .en: "Appearance"],
        "prefs.defaultFormat": [.zh: "默认输出格式", .en: "Default output format"],
        "prefs.defaultMode": [.zh: "默认分段模式", .en: "Default segment mode"],
        "prefs.modelPath": [.zh: "默认模型路径", .en: "Default model path"],
        "prefs.modelPath.choose": [.zh: "浏览…", .en: "Browse…"],
        "prefs.uiLanguage": [.zh: "界面语言", .en: "Interface language"]
    ]
}
