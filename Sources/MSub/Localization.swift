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
        "settings.decoding": [.zh: "AED 解码", .en: "AED decoding"],
        "settings.softmaxSmoothing": [.zh: "平滑温度", .en: "Softmax smoothing"],
        "settings.lengthPenalty": [.zh: "长度惩罚", .en: "Length penalty"],
        "settings.eosPenalty": [.zh: "结束惩罚", .en: "EOS penalty"],
        "settings.decodeMaxLen": [.zh: "最大解码长度", .en: "Max decode length"],
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
        "editor.empty": [.zh: "暂无可编辑字幕", .en: "No editable subtitles"],
        "editor.empty.help": [.zh: "生成 SRT/VTT/JSON 字幕后，会在这里按字幕块显示并支持编辑。", .en: "Generate SRT/VTT/JSON subtitles to edit them here as cue blocks."],
        "editor.timeline": [.zh: "波形时间轴", .en: "Waveform timeline"],
        "editor.timelineHelp": [.zh: "拖动字幕块两侧手柄可调整开始/结束时间；点击波形空白处可调整播放位置。", .en: "Drag cue handles to adjust start/end time; click empty waveform area to move the playback cursor."],
        "editor.handleStart.help": [.zh: "拖动调整该字幕块的开始时间", .en: "Drag to adjust the cue's start time"],
        "editor.handleEnd.help": [.zh: "拖动调整该字幕块的结束时间", .en: "Drag to adjust the cue's end time"],
        "editor.play": [.zh: "播放", .en: "Play"],
        "editor.pause": [.zh: "暂停", .en: "Pause"],
        "editor.playCurrent": [.zh: "仅播放当前段落", .en: "Play Current Cue"],
        "editor.playCurrent.help": [.zh: "从当前字幕块开始播放，并在该字幕块结束时自动停止。", .en: "Play from the selected cue start and stop automatically at that cue's end."],
        "editor.selected": [.zh: "当前字幕块", .en: "Selected cue"],
        "editor.selectHelp": [.zh: "在左侧选择一个字幕块后，可编辑文字和时间。", .en: "Select a cue on the left to edit text and timing."],
        "editor.start": [.zh: "开始", .en: "Start"],
        "editor.end": [.zh: "结束", .en: "End"],
        "editor.duration": [.zh: "持续时间", .en: "Duration"],
        "editor.dragHelp": [.zh: "时间轴中的左右手柄可拖动调整持续时间；点击字幕块会让视频跳转到对应位置。", .en: "Drag the timeline handles to adjust duration; selecting a cue seeks the video to that time."],
        "editor.zoom": [.zh: "缩放", .en: "Zoom"],
        "editor.zoomIn": [.zh: "放大时间轴", .en: "Zoom in"],
        "editor.zoomOut": [.zh: "缩小时间轴", .en: "Zoom out"],
        "editor.previous": [.zh: "上一个", .en: "Previous"],
        "editor.next": [.zh: "下一个", .en: "Next"],
        "editor.addAfter": [.zh: "在后方新建空字幕块", .en: "Add Empty Cue After"],
        "editor.addAfter.help": [.zh: "在当前字幕块后插入一个空字幕块，并选中新建块。", .en: "Insert an empty cue after the selected cue and select it."],
        "editor.find": [.zh: "查找文字", .en: "Find text"],
        "editor.findHint": [.zh: "输入文字以查找字幕", .en: "Enter text to search cues"],
        "editor.findNext": [.zh: "下一个", .en: "Next"],
        "editor.findNext.help": [.zh: "跳转到下一个包含查找文字的字幕块。", .en: "Jump to the next cue containing the search text."],
        "editor.findCount": [.zh: "%d 处匹配", .en: "%d matches"],
        "editor.findSelected": [.zh: "已跳转到第 %d 条", .en: "Selected cue %d"],
        "editor.findNoMatch": [.zh: "没有匹配项", .en: "No matches"],
        "editor.replace": [.zh: "替换为", .en: "Replace with"],
        "editor.replaceCurrent": [.zh: "替换当前", .en: "Replace"],
        "editor.replaceCurrent.help": [.zh: "替换当前字幕块中的第一处匹配；若当前块没有匹配，会先查找下一个。", .en: "Replace the first match in the selected cue; if none, find the next match first."],
        "editor.replaceAll": [.zh: "全部替换", .en: "Replace All"],
        "editor.replaceAll.help": [.zh: "替换所有字幕块中的匹配文字。", .en: "Replace matching text across all cues."],
        "editor.replaceOneCount": [.zh: "已替换 %d 处", .en: "Replaced %d match"],
        "editor.replaceAllCount": [.zh: "已替换 %d 处", .en: "Replaced %d matches"],
        "editor.matchCase": [.zh: "区分大小写", .en: "Match case"],
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
        "status.sameDirectory": [.zh: "已保存到原视频目录", .en: "Saved beside source media"],
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
        "help.softmaxSmoothing": [.zh: "FireRedASR2-AED beam search 中的 softmax 平滑系数。默认 1.25；调高会让候选分布更平，可能更稳但也可能更保守。", .en: "Softmax smoothing used by FireRedASR2-AED beam search. Default is 1.25; higher flattens candidate probabilities and can be steadier but more conservative."],
        "help.lengthPenalty": [.zh: "AED 的长度归一化惩罚。默认 0.6；较高会更偏向较长输出，较低会更接近原始得分。", .en: "Length normalization penalty for AED decoding. Default is 0.6; higher favors longer outputs, lower stays closer to raw scores."],
        "help.eosPenalty": [.zh: "结束符得分惩罚。默认 1.0；提高可能让模型更早结束，降低可能减少过早截断。", .en: "EOS score penalty. Default is 1.0; higher can end earlier, lower can reduce premature stops."],
        "help.decodeMaxLen": [.zh: "限制单段最多解码 token 数。0 表示由音频长度自动决定；长音频不建议过高。", .en: "Maximum decoded tokens per segment. 0 lets the model decide from audio length; avoid very high values for long audio."],
        "help.unsupportedDecoding": [.zh: "当前 MLX 版 FireRedASR2-AED 不读取 temperature、repetition penalty 或热词/高频词偏置；这些属于 LLM 分支或需要额外解码器支持。", .en: "The current MLX FireRedASR2-AED path does not read temperature, repetition penalty, or hotword bias; those belong to the LLM path or require decoder support."],
        "help.saveAll": [.zh: "将所有已生成或已修改的字幕保存到各自视频文件所在目录，文件名与视频同名。", .en: "Save every generated or edited subtitle beside its source media using the media filename."],

        "tab.segments": [.zh: "分段", .en: "Segments"],
        "tab.output": [.zh: "字幕", .en: "Output"],
        "preview.title": [.zh: "预览", .en: "Preview"],
        "preview.show": [.zh: "显示预览", .en: "Show preview"],
        "preview.unsupported": [.zh: "此文件无法显示预览。", .en: "Preview not available for this file."],
        "media.info": [.zh: "视频信息", .en: "Media Info"],
        "media.name": [.zh: "文件", .en: "File"],
        "media.duration": [.zh: "时长", .en: "Duration"],
        "media.size": [.zh: "大小", .en: "Size"],
        "media.resolution": [.zh: "分辨率", .en: "Resolution"],
        "media.frameRate": [.zh: "帧率", .en: "Frame rate"],
        "media.videoCodec": [.zh: "视频编码", .en: "Video codec"],
        "media.audio": [.zh: "音频", .en: "Audio"],
        "media.bitRate": [.zh: "码率", .en: "Bit rate"],
        "media.noVideo": [.zh: "无视频轨", .en: "No video track"],
        "media.channels": [.zh: "%d 声道", .en: "%d ch"],
        "media.frequentTerms": [.zh: "字幕高频词", .en: "Frequent subtitle terms"],

        "prefs.title": [.zh: "偏好设置", .en: "Settings"],
        "prefs.general": [.zh: "通用", .en: "General"],
        "prefs.model": [.zh: "模型", .en: "Model"],
        "prefs.appearance": [.zh: "外观", .en: "Appearance"],
        "prefs.defaultFormat": [.zh: "默认输出格式", .en: "Default output format"],
        "prefs.defaultMode": [.zh: "默认分段模式", .en: "Default segment mode"],
        "prefs.modelPath": [.zh: "默认模型路径", .en: "Default model path"],
        "prefs.modelPath.choose": [.zh: "浏览…", .en: "Browse…"],
        "prefs.uiLanguage": [.zh: "界面语言", .en: "Interface language"],
        "menu.file": [.zh: "文件", .en: "File"],
        "menu.openFile": [.zh: "打开文件…", .en: "Open File…"],
        "menu.openRecent": [.zh: "打开最近文件", .en: "Open Recent"],
        "menu.noRecentFiles": [.zh: "没有最近文件", .en: "No Recent Files"],
        "menu.clearRecentFiles": [.zh: "清除最近文件", .en: "Clear Recent Files"],
        "menu.edit": [.zh: "编辑", .en: "Edit"],
        "menu.view": [.zh: "显示", .en: "View"],
        "menu.window": [.zh: "窗口", .en: "Window"],
        "menu.help": [.zh: "帮助", .en: "Help"],
        "menu.aboutApp": [.zh: "关于 %@", .en: "About %@"],
        "menu.settings": [.zh: "设置…", .en: "Settings…"],
        "menu.services": [.zh: "服务", .en: "Services"],
        "menu.hideApp": [.zh: "隐藏 %@", .en: "Hide %@"],
        "menu.hideOthers": [.zh: "隐藏其他", .en: "Hide Others"],
        "menu.showAll": [.zh: "全部显示", .en: "Show All"],
        "menu.quitApp": [.zh: "退出 %@", .en: "Quit %@"],
        "menu.closeWindow": [.zh: "关闭窗口", .en: "Close Window"],
        "menu.undo": [.zh: "撤销", .en: "Undo"],
        "menu.redo": [.zh: "重做", .en: "Redo"],
        "menu.cut": [.zh: "剪切", .en: "Cut"],
        "menu.copy": [.zh: "复制", .en: "Copy"],
        "menu.paste": [.zh: "粘贴", .en: "Paste"],
        "menu.delete": [.zh: "删除", .en: "Delete"],
        "menu.selectAll": [.zh: "全选", .en: "Select All"],
        "menu.toggleSidebar": [.zh: "显示/隐藏侧边栏", .en: "Show/Hide Sidebar"],
        "menu.fullScreen": [.zh: "进入全屏幕", .en: "Enter Full Screen"],
        "menu.minimize": [.zh: "最小化", .en: "Minimize"],
        "menu.zoom": [.zh: "缩放", .en: "Zoom"],
        "menu.bringAllToFront": [.zh: "全部置于前面", .en: "Bring All to Front"],
        "menu.helpApp": [.zh: "%@ 帮助", .en: "%@ Help"]
    ]
}
