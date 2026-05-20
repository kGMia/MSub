import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MSubApp: App {
    @StateObject private var api = APIClient()
    @StateObject private var backend = BackendService()
    @StateObject private var settings = TranscriptionSettings()

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
                .environment(\.locale, language.locale)
                .frame(minWidth: 900, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
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
