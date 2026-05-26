import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MSubApp: App {
    @StateObject private var api = APIClient()
    @StateObject private var backend = BackendService()
    @StateObject private var settings = TranscriptionSettings()
    @StateObject private var recentFiles = RecentFilesStore()

    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue

    init() {
        AppLanguageBootstrap.applyStoredLanguageIfNeeded()
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .zh
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
                .environmentObject(backend)
                .environmentObject(settings)
                .environmentObject(recentFiles)
                .environment(\.locale, language.locale)
                .frame(minWidth: 820, minHeight: 640)
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
        }

        Settings {
            PreferencesView()
                .environmentObject(settings)
                .environment(\.locale, language.locale)
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

// MARK: - Preferences Window

struct PreferencesView: View {
    @EnvironmentObject private var settings: TranscriptionSettings
    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue
    @State private var pendingRelaunchLanguage: AppLanguage?

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
        VStack(alignment: .leading, spacing: 14) {
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
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var modelTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("prefs.modelPath"))
                .font(.callout.weight(.medium))
            HStack {
                TextField("", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button(t("prefs.modelPath.choose")) {
                    chooseModelDirectory()
                }
            }
            Text(Copy.text("help.model", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            stackedRow(t("prefs.uiLanguage")) {
                Picker("", selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
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

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.model = url.path
        }
    }
}
