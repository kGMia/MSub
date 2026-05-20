import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MSubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var api = APIClient()
    @StateObject private var backend = BackendService()
    @StateObject private var settings = TranscriptionSettings()
    @StateObject private var recentFiles = RecentFilesStore()

    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue

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
                .background(MenuLocalizationBridge(language: language))
                .frame(minWidth: 900, minHeight: 640)
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
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(settings)
                .environment(\.locale, language.locale)
                .background(MenuLocalizationBridge(language: language))
                .frame(width: 420, height: 280)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuLocalizationBridge: View {
    let language: AppLanguage

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MenuLocalizer.apply(language: language, retries: 4)
            }
            .onChange(of: language) { _, newValue in
                MenuLocalizer.apply(language: newValue, retries: 4)
            }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyMenuLocalization()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyMenuLocalization()
    }

    private func applyMenuLocalization() {
        let raw = UserDefaults.standard.string(forKey: "huz.uiLanguage") ?? AppLanguage.zh.rawValue
        let language = AppLanguage(rawValue: raw) ?? .zh
        Task { @MainActor in
            MenuLocalizer.apply(language: language, retries: 8)
        }
    }
}

@MainActor
private enum MenuLocalizer {
    static func apply(language: AppLanguage, retries: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
            updateMainMenu(language: language)
        }
        guard retries > 0 else { return }
        for attempt in 1...retries {
            let delay = DispatchTimeInterval.milliseconds(80 * attempt)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                updateMainMenu(language: language)
            }
        }
    }

    private static func updateMainMenu(language: AppLanguage) {
        guard let mainMenu = NSApp.mainMenu else { return }
        let appName = Copy.text("app.title", language: language)

        setTopMenu(mainMenu, index: 1, title: text("menu.file", language))
        setTopMenu(mainMenu, index: 2, title: text("menu.edit", language))
        setTopMenu(mainMenu, index: 3, title: text("menu.view", language))
        setTopMenu(mainMenu, index: 4, title: text("menu.window", language))
        setTopMenu(mainMenu, index: 5, title: text("menu.help", language))

        setAction("orderFrontStandardAboutPanel:", title: String(format: text("menu.aboutApp", language), appName), in: mainMenu)
        setAction("showSettingsWindow:", title: text("menu.settings", language), in: mainMenu)
        setSubmenu(NSApp.servicesMenu, title: text("menu.services", language), in: mainMenu)
        setAction("hide:", title: String(format: text("menu.hideApp", language), appName), in: mainMenu)
        setAction("hideOtherApplications:", title: text("menu.hideOthers", language), in: mainMenu)
        setAction("unhideAllApplications:", title: text("menu.showAll", language), in: mainMenu)
        setAction("terminate:", title: String(format: text("menu.quitApp", language), appName), in: mainMenu)

        setAction("performClose:", title: text("menu.closeWindow", language), in: mainMenu)
        setAction("undo:", title: text("menu.undo", language), in: mainMenu)
        setAction("redo:", title: text("menu.redo", language), in: mainMenu)
        setAction("cut:", title: text("menu.cut", language), in: mainMenu)
        setAction("copy:", title: text("menu.copy", language), in: mainMenu)
        setAction("paste:", title: text("menu.paste", language), in: mainMenu)
        setAction("delete:", title: text("menu.delete", language), in: mainMenu)
        setAction("selectAll:", title: text("menu.selectAll", language), in: mainMenu)
        setAction("toggleSidebar:", title: text("menu.toggleSidebar", language), in: mainMenu)
        setAction("toggleFullScreen:", title: text("menu.fullScreen", language), in: mainMenu)
        setAction("performMiniaturize:", title: text("menu.minimize", language), in: mainMenu)
        setAction("performZoom:", title: text("menu.zoom", language), in: mainMenu)
        setAction("arrangeInFront:", title: text("menu.bringAllToFront", language), in: mainMenu)
        setAction("showHelp:", title: String(format: text("menu.helpApp", language), appName), in: mainMenu)
    }

    private static func text(_ key: String, _ language: AppLanguage) -> String {
        Copy.text(key, language: language)
    }

    private static func setTopMenu(_ menu: NSMenu, index: Int, title: String) {
        guard menu.items.indices.contains(index) else { return }
        let item = menu.items[index]
        item.title = title
        item.submenu?.title = title
    }

    private static func setAction(_ selectorName: String, title: String, in menu: NSMenu) {
        let selector = NSSelectorFromString(selectorName)
        for item in menu.items {
            if item.action == selector {
                item.title = title
            }
            if let submenu = item.submenu {
                setAction(selectorName, title: title, in: submenu)
            }
        }
    }

    private static func setSubmenu(_ submenu: NSMenu?, title: String, in menu: NSMenu) {
        guard let submenu else { return }
        submenu.title = title
        for item in menu.items {
            if item.submenu === submenu {
                item.title = title
            }
            if let nested = item.submenu {
                setSubmenu(submenu, title: title, in: nested)
            }
        }
    }
}

// MARK: - Preferences Window

struct PreferencesView: View {
    @EnvironmentObject private var settings: TranscriptionSettings
    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue

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
            languageRaw = newValue.rawValue
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
