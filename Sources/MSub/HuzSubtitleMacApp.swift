import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppLinks {
    static let homepage = URL(string: "https://github.com/kGMia/MSub")!
    static let issues = URL(string: "https://github.com/kGMia/MSub/issues")!
    static let copyrightHolder = "kGMia"
}

enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct MSubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var api = APIClient()
    @State private var backend = BackendService()
    @State private var settings = TranscriptionSettings()
    @State private var recentFiles = RecentFilesStore()

    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue
    @AppStorage("huz.appearanceTheme") private var appearanceRaw = AppearanceTheme.system.rawValue

    init() {
        AppLanguageBootstrap.applyStoredLanguageIfNeeded()
        BackendService.terminateRecordedBackendProcesses()
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .zh
    }

    private var appearance: AppearanceTheme {
        AppearanceTheme(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        Window("MSub", id: "main") {
            ContentView()
                .environment(api)
                .environment(backend)
                .environment(settings)
                .environment(recentFiles)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 820, minHeight: 640)
                .onAppear {
                    DockMenuState.shared.recentFiles = recentFiles
                    let pending = DockMenuState.shared.takePendingOpenURLs()
                    for url in pending {
                        NotificationCenter.default.post(name: .msubOpenRecentFileRequested, object: url)
                    }
                    DockMenuState.shared.isReady = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    backend.stop(waitForExit: true)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(Copy.text("menu.openFile", language: language)) {
                    NotificationCenter.default.post(name: .msubOpenFilesRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Menu(Copy.text("menu.openRecent", language: language)) {
                    if recentFiles.urls.isEmpty {
                        Text(Copy.text("menu.noRecentFiles", language: language))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentFiles.urls, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                NotificationCenter.default.post(name: .msubOpenRecentFileRequested, object: url)
                            }
                        }
                        Divider()
                        Button(Copy.text("menu.clearRecentFiles", language: language)) {
                            recentFiles.clear()
                        }
                    }
                }

                Button(Copy.text("menu.importSubtitle", language: language)) {
                    NotificationCenter.default.post(name: .msubImportSubtitleRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(Copy.text("menu.authorizeSidecarFolder", language: language)) {
                    NotificationCenter.default.post(name: .msubAuthorizeSidecarFolderRequested, object: nil)
                }
            }

            CommandGroup(after: .saveItem) {
                Button(Copy.text("menu.saveAll", language: language)) {
                    NotificationCenter.default.post(name: .msubSaveAllRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button(Copy.text("menu.deleteCue", language: language)) {
                    NotificationCenter.default.post(name: .msubDeleteSelectedCueRequested, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])

                Button(Copy.text("menu.duplicateCue", language: language)) {
                    NotificationCenter.default.post(name: .msubDuplicateSelectedCueRequested, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(Copy.text("menu.resetCue", language: language)) {
                    NotificationCenter.default.post(name: .msubResetSelectedCueRequested, object: nil)
                }

                Button(Copy.text("menu.insertCueBefore", language: language)) {
                    NotificationCenter.default.post(name: .msubInsertCueBeforeRequested, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button(Copy.text("menu.insertCueAfter", language: language)) {
                    NotificationCenter.default.post(name: .msubInsertCueAfterRequested, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            }

            CommandMenu(Copy.text("menu.subtitle", language: language)) {
                Button(Copy.text("menu.transcribe", language: language)) {
                    NotificationCenter.default.post(name: .msubTranscribeRequested, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button(Copy.text("menu.preview", language: language)) {
                    NotificationCenter.default.post(name: .msubPreviewRequested, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button(Copy.text("menu.stopProcessing", language: language)) {
                    NotificationCenter.default.post(name: .msubStopRequested, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])

                Divider()

                Button(Copy.text("translation.translate", language: language)) {
                    NotificationCenter.default.post(name: .msubTranslateRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Divider()

                Button(Copy.text("menu.adjustTiming", language: language)) {
                    NotificationCenter.default.post(name: .msubAdjustTimingRequested, object: nil)
                }

                Button(Copy.text("menu.toggleTimeline", language: language)) {
                    NotificationCenter.default.post(name: .msubToggleTimelineRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(Copy.text("menu.zoomTimelineIn", language: language)) {
                    NotificationCenter.default.post(name: .msubZoomTimelineInRequested, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command, .option])

                Button(Copy.text("menu.zoomTimelineOut", language: language)) {
                    NotificationCenter.default.post(name: .msubZoomTimelineOutRequested, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .appInfo) {
                Button(String(format: Copy.text("menu.aboutApp", language: language), AppAbout.appName)) {
                    AppAbout.showPanel(language: language)
                }
            }

            CommandGroup(replacing: .help) {
                Button(Copy.text("help.homepage", language: language)) {
                    NSWorkspace.shared.open(AppLinks.homepage)
                }
                Button(Copy.text("help.reportIssue", language: language)) {
                    NSWorkspace.shared.open(AppLinks.issues)
                }
            }
        }

        Settings {
            PreferencesView()
                .environment(settings)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
                .frame(width: 420, height: 280)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Language bootstrap

/// Syncs the user's stored UI language preference into `AppleLanguages` so that
/// macOS itself localizes the system-provided menu items (App menu, Cut/Copy/Paste,
/// Window, Help, etc.) on the next launch. Switching language at runtime requires
/// a relaunch — this is the same pattern Apple's own apps use.
enum AppLanguageBootstrap {
    private static let appleLanguagesKey = "AppleLanguages"

    static func applyStoredLanguageIfNeeded() {
        let raw = UserDefaults.standard.string(forKey: "huz.uiLanguage") ?? AppLanguage.zh.rawValue
        let target = AppLanguage(rawValue: raw) ?? .zh
        let current = (UserDefaults.standard.array(forKey: appleLanguagesKey) as? [String])?.first
        if current != target.localeIdentifier {
            UserDefaults.standard.set([target.localeIdentifier], forKey: appleLanguagesKey)
        }
    }

    /// Updates both the stored preference and `AppleLanguages`. Returns `true`
    /// if a relaunch is needed to apply the change to system-provided menus.
    static func setLanguage(_ language: AppLanguage) -> Bool {
        let previous = (UserDefaults.standard.array(forKey: appleLanguagesKey) as? [String])?.first
        UserDefaults.standard.set(language.rawValue, forKey: "huz.uiLanguage")
        UserDefaults.standard.set([language.localeIdentifier], forKey: appleLanguagesKey)
        return previous != language.localeIdentifier
    }

    @MainActor
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - About panel

enum AppAbout {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "MSub"
    }

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    @MainActor
    static func showPanel(language: AppLanguage) {
        let credits = NSMutableAttributedString()
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .link: AppLinks.homepage,
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let plainAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11)
        ]
        credits.append(NSAttributedString(
            string: Copy.text("about.homepage", language: language) + ": ",
            attributes: plainAttrs
        ))
        credits.append(NSAttributedString(
            string: AppLinks.homepage.absoluteString,
            attributes: linkAttrs
        ))
        credits.append(NSAttributedString(string: "\n", attributes: plainAttrs))
        credits.append(NSAttributedString(
            string: Copy.text("about.reportIssue", language: language) + ": ",
            attributes: plainAttrs
        ))
        credits.append(NSAttributedString(
            string: AppLinks.issues.absoluteString,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .link: AppLinks.issues,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        ))

        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let copyright = String(
            format: Copy.text("about.copyright", language: language),
            String(year),
            AppLinks.copyrightHolder
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .applicationVersion: shortVersion,
            .version: buildNumber,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright
        ]

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

// MARK: - Preferences Window

struct PreferencesView: View {
    @Environment(TranscriptionSettings.self) private var settings
    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue
    @AppStorage("huz.appearanceTheme") private var appearanceRaw = AppearanceTheme.system.rawValue
    @State private var pendingRelaunchLanguage: AppLanguage?
    private let visibleASREngines: [ASREngine] = [.fireredasr2, .sensevoice, .mimo, .apple]
    private let visibleVADEngines: [VADEngine] = [.firered, .energy]

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .zh
    }

    private func t(_ key: String) -> String { Copy.text(key, language: language) }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(t("prefs.general"), systemImage: "gearshape") }
            modelTab
                .tabItem { Label(t("prefs.model"), systemImage: "cube") }
            appearanceTab
                .tabItem { Label(t("prefs.appearance"), systemImage: "paintbrush") }
        }
        .padding(12)
        .alert(
            t("prefs.relaunchTitle"),
            isPresented: relaunchAlertBinding,
            presenting: pendingRelaunchLanguage
        ) { _ in
            Button(t("prefs.relaunchNow")) {
                pendingRelaunchLanguage = nil
                AppLanguageBootstrap.relaunchApp()
            }
            Button(t("prefs.relaunchLater"), role: .cancel) {
                pendingRelaunchLanguage = nil
            }
        } message: { _ in
            Text(t("prefs.relaunchMessage"))
        }
    }

    private var relaunchAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingRelaunchLanguage != nil },
            set: { if !$0 { pendingRelaunchLanguage = nil } }
        )
    }

    private var generalTab: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            stackedRow(t("prefs.defaultFormat")) {
                Picker("", selection: $settings.format) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            stackedRow(t("prefs.defaultMode")) {
                Picker("", selection: $settings.segmentMode) {
                    ForEach(SegmentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            stackedRow(t("settings.vadEngine")) {
                Picker("", selection: $settings.vadEngine) {
                    ForEach(visibleVADEngines) { engine in
                        Text(t("settings.vadEngine.\(engine.rawValue)")).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var modelTab: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 10) {
            stackedRow(t("settings.asrEngine")) {
                Picker("", selection: $settings.asrEngine) {
                    ForEach(visibleASREngines) { engine in
                        Text(t("settings.asrEngine.\(engine.rawValue)")).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: settings.asrEngine) { _, newValue in
                    settings.selectASREngine(newValue)
                }
            }

            if settings.effectiveASREngine == .apple {
                Text(modelHelpText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(t("prefs.modelPath"))
                    .font(.callout.weight(.medium))
                HStack {
                    TextField("", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onChange(of: settings.model) { _, _ in
                            settings.modelPathDidChange()
                        }
                    Button(t("prefs.modelPath.choose")) {
                        chooseModelDirectory()
                    }
                }
                Text(modelHelpText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var appearanceTab: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            stackedRow(t("prefs.uiLanguage")) {
                Picker("", selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            stackedRow(t("prefs.theme")) {
                Picker("", selection: themeBinding) {
                    ForEach(AppearanceTheme.allCases) { theme in
                        Text(t("prefs.theme.\(theme.rawValue)")).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Toggle(t("settings.timelineSpeakerMarkers"), isOn: $settings.timelineSpeakerMarkersEnabled)
                .toggleStyle(.switch)
            stackedRow(t("settings.waveformResolution")) {
                Picker("", selection: $settings.waveformResolution) {
                    ForEach(WaveformResolution.allCases) { resolution in
                        Text(t("settings.waveformResolution.\(resolution.rawValue)")).tag(resolution)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func stackedRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
            content()
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            language
        } set: { newValue in
            guard newValue != language else { return }
            let needsRelaunch = AppLanguageBootstrap.setLanguage(newValue)
            if needsRelaunch {
                pendingRelaunchLanguage = newValue
            }
        }
    }

    private var themeBinding: Binding<AppearanceTheme> {
        Binding {
            AppearanceTheme(rawValue: appearanceRaw) ?? .system
        } set: { newValue in
            appearanceRaw = newValue.rawValue
        }
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.model = url.path
            settings.modelPathDidChange()
        }
    }

    private func modelHelpText() -> String {
        let key = "help.model.\(settings.effectiveASREngine.rawValue)"
        let localized = t(key)
        return localized == key ? t("help.model") : localized
    }
}

// MARK: - Dock menu

@MainActor
final class DockMenuState {
    static let shared = DockMenuState()
    private init() {}

    weak var recentFiles: RecentFilesStore?
    var isReady = false
    private var pendingOpenURLs: [URL] = []

    func enqueueOpenURL(_ url: URL) {
        pendingOpenURLs.append(url)
    }

    func takePendingOpenURLs() -> [URL] {
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        return urls
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        BackendService.terminateRecordedBackendProcesses()
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let raw = UserDefaults.standard.string(forKey: "huz.uiLanguage") ?? AppLanguage.zh.rawValue
        let language = AppLanguage(rawValue: raw) ?? .zh
        let urls = DockMenuState.shared.recentFiles?.urls ?? []

        let menu = NSMenu()
        if urls.isEmpty {
            let empty = NSMenuItem(
                title: Copy.text("menu.noRecentFiles", language: language),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in urls {
                let item = NSMenuItem(
                    title: url.lastPathComponent,
                    action: #selector(openRecentFile(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = url
                item.toolTip = url.path
                menu.addItem(item)
            }
        }
        return menu
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if DockMenuState.shared.isReady {
            for url in urls {
                NotificationCenter.default.post(name: .msubOpenRecentFileRequested, object: url)
            }
        } else {
            for url in urls {
                DockMenuState.shared.enqueueOpenURL(url)
            }
        }
    }

    @MainActor
    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NotificationCenter.default.post(name: .msubOpenRecentFileRequested, object: url)
    }
}
