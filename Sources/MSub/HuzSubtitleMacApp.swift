import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum AppLinks {
    static let homepage = URL(string: "https://github.com/kGMia/MSub")!
    static let issues = URL(string: "https://github.com/kGMia/MSub/issues")!
    static let releases = URL(string: "https://github.com/kGMia/MSub/releases")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/kGMia/MSub/releases/latest")!
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
    @State private var isCheckingForUpdates = false

    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.systemDefault.rawValue
    @AppStorage("huz.appearanceTheme") private var appearanceRaw = AppearanceTheme.system.rawValue

    init() {
        MSubCommandLine.handleLaunchArguments()
        AppLanguageBootstrap.applyStoredLanguageIfNeeded()
        BackendService.terminateRecordedBackendProcesses()
        MediaProcessingCleanup.cleanupAfterLaunch()
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .systemDefault
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
                    DockMenuState.shared.isReady = true
                    DockMenuState.shared.enqueueLaunchCommandsIfNeeded()
                    DockMenuState.shared.flushPendingAutomation()
                }
                .task {
                    let stream = NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification)
                    for await _ in stream {
                        backend.stop(waitForExit: true)
                        MediaProcessingCleanup.cleanupBeforeTerminate()
                        break
                    }
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

                Button(Copy.text("menu.importSubtitleFromClipboard", language: language)) {
                    NotificationCenter.default.post(name: .msubImportSubtitleFromClipboardRequested, object: nil)
                }

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

                Divider()

                Button(Copy.text("menu.findInSubtitles", language: language)) {
                    NotificationCenter.default.post(name: .msubFindInSubtitlesRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Divider()

                Button(Copy.text("menu.showSegmentsTab", language: language)) {
                    NotificationCenter.default.post(name: .msubShowSegmentsTabRequested, object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button(Copy.text("menu.showOutputTab", language: language)) {
                    NotificationCenter.default.post(name: .msubShowOutputTabRequested, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button(Copy.text("menu.showCueListTab", language: language)) {
                    NotificationCenter.default.post(name: .msubShowCueListTabRequested, object: nil)
                }
                .keyboardShortcut("3", modifiers: [.command])
            }

            CommandGroup(replacing: .appInfo) {
                Button(String(format: Copy.text("menu.aboutApp", language: language), AppAbout.appName)) {
                    AppAbout.showPanel(language: language)
                }
                Button(Copy.text(isCheckingForUpdates ? "menu.checkingForUpdates" : "menu.checkForUpdates", language: language)) {
                    Task { await checkForUpdates() }
                }
                .disabled(isCheckingForUpdates)
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
                .environment(api)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
                .frame(width: 480, height: 400)
        }
        .windowResizability(.contentSize)
    }

    @MainActor
    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        await AppUpdateChecker.checkAndPresent(language: language)
    }
}

// MARK: - Model manager (Settings pane)

struct ModelManagerView: View {
    @Environment(APIClient.self) private var api
    let language: AppLanguage

    @State private var modelList: ManagedModelList?
    @State private var errorMessage: String?
    @State private var busyModels: Set<String> = []
    @State private var pendingDeletion: ManagedModel?
    @State private var refreshTrigger = 0

    private func t(_ key: String) -> String { Copy.text(key, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let modelList {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(modelList.models) { model in
                            modelRow(model)
                        }
                    }
                }
                Text(modelList.modelsDir)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if errorMessage == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .task(id: refreshTrigger) { await refreshLoop() }
        .confirmationDialog(
            t("models.deleteConfirmTitle"),
            isPresented: deleteConfirmBinding,
            presenting: pendingDeletion
        ) { model in
            Button(t("models.delete"), role: .destructive) {
                pendingDeletion = nil
                performAction(model.name) { try await api.deleteModel(named: $0) }
            }
            Button(t("models.deleteCancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { model in
            Text("\(model.name) · \(formattedSize(model.sizeBytes))")
        }
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func modelRow(_ model: ManagedModel) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(t("models.feature.\(model.feature)"))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if model.isDownloading {
                        if let fraction = model.downloadFraction {
                            Text("\(t("models.downloading")) \(Int(fraction * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(t("models.downloading"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if model.installed {
                        Text(formattedSize(model.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(t("models.notInstalled"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let downloadError = model.downloadError, !downloadError.isEmpty {
                        Text(downloadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if model.isDownloading, let fraction = model.downloadFraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 72)
            } else if model.isDownloading || busyModels.contains(model.name) {
                ProgressView()
                    .controlSize(.small)
            } else if model.installed {
                Button(t("models.delete"), role: .destructive) {
                    pendingDeletion = model
                }
                .controlSize(.small)
            } else if model.downloadable {
                Button(t("models.download")) {
                    performAction(model.name) { try await api.downloadModel(named: $0) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                let list = try await api.fetchModels()
                modelList = list
                errorMessage = nil
                guard list.models.contains(where: { $0.isDownloading }) else { return }
            } catch {
                if modelList == nil {
                    errorMessage = t("models.backendUnavailable")
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func performAction(
        _ name: String,
        _ operation: @escaping (String) async throws -> Void
    ) {
        busyModels.insert(name)
        Task {
            do {
                try await operation(name)
            } catch {
                errorMessage = error.localizedDescription
            }
            busyModels.remove(name)
            refreshTrigger += 1
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
        let raw: String
        if let stored = UserDefaults.standard.string(forKey: "huz.uiLanguage") {
            raw = stored
        } else {
            let systemLanguage = AppLanguage.systemDefault
            UserDefaults.standard.set(systemLanguage.rawValue, forKey: "huz.uiLanguage")
            raw = systemLanguage.rawValue
        }
        let target = AppLanguage(rawValue: raw) ?? .systemDefault
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

    static var shortVersion: String {
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

// MARK: - Updates

enum AppUpdateChecker {
    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
        }
    }

    @MainActor
    static func checkAndPresent(language: AppLanguage) async {
        do {
            let release = try await fetchLatestRelease()
            present(release: release, currentVersion: AppAbout.shortVersion, language: language)
        } catch {
            presentError(error, language: language)
        }
    }

    private static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: AppLinks.latestReleaseAPI)
        request.timeoutInterval = 12
        request.setValue("MSub", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    @MainActor
    private static func present(release: GitHubRelease, currentVersion: String, language: AppLanguage) {
        let latestVersion = displayVersion(from: release.tagName)
        let hasUpdate = compareVersions(latestVersion, currentVersion) == .orderedDescending
        let alert = NSAlert()
        alert.alertStyle = hasUpdate ? .informational : .informational
        if hasUpdate {
            alert.messageText = Copy.text("update.available.title", language: language)
            alert.informativeText = String(
                format: Copy.text("update.available.message", language: language),
                latestVersion,
                currentVersion
            )
            alert.addButton(withTitle: Copy.text("update.openRelease", language: language))
            alert.addButton(withTitle: Copy.text("button.cancel", language: language))
        } else {
            alert.messageText = Copy.text("update.upToDate.title", language: language)
            alert.informativeText = String(
                format: Copy.text("update.upToDate.message", language: language),
                currentVersion
            )
            alert.addButton(withTitle: Copy.text("button.ok", language: language))
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if hasUpdate, response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    @MainActor
    private static func presentError(_ error: Error, language: AppLanguage) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Copy.text("update.failed.title", language: language)
        alert.informativeText = String(
            format: Copy.text("update.failed.message", language: language),
            readableMessage(for: error, language: language)
        )
        alert.addButton(withTitle: Copy.text("button.ok", language: language))
        alert.addButton(withTitle: Copy.text("update.openReleases", language: language))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(AppLinks.releases)
        }
    }

    private static func readableMessage(for error: Error, language: AppLanguage) -> String {
        if let updateError = error as? UpdateCheckError {
            return updateError.localizedDescription(language: language)
        }
        return error.localizedDescription
    }

    private static func displayVersion(from tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        guard !left.isEmpty, !right.isEmpty else { return .orderedSame }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lValue = index < left.count ? left[index] : 0
            let rValue = index < right.count ? right[index] : 0
            if lValue > rValue { return .orderedDescending }
            if lValue < rValue { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func versionComponents(_ version: String) -> [Int] {
        let pattern = #"\d+(?:\.\d+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)),
              let range = Range(match.range, in: version) else {
            return []
        }
        return version[range].split(separator: ".").compactMap { Int($0) }
    }

    private enum UpdateCheckError: Error {
        case invalidResponse
        case httpStatus(Int)

        func localizedDescription(language: AppLanguage) -> String {
            switch self {
            case .invalidResponse:
                return Copy.text("update.error.invalidResponse", language: language)
            case .httpStatus(let status):
                return String(format: Copy.text("update.error.httpStatus", language: language), status)
            }
        }
    }
}

// MARK: - Agent control

enum MSubAutomationCommand: Sendable {
    case open(URL)
    case preview
    case transcribe
    case stop
    case saveAll
    case showSegments
    case showOutput
    case showCueList
    case setLanguage(AppLanguage)
    case setTheme(AppearanceTheme)
}

enum MSubCommandLine {
    private static let launchParseResult = parse(arguments: Array(CommandLine.arguments.dropFirst()))

    static func handleLaunchArguments() {
        switch launchParseResult {
        case .none:
            return
        case .help:
            FileHandle.standardOutput.write(Data(helpText.utf8))
            Darwin.exit(0)
        case .version:
            FileHandle.standardOutput.write(Data("\(AppAbout.appName)\n".utf8))
            Darwin.exit(0)
        case .commands(let commands):
            if commands.isEmpty {
                return
            }
        case .error(let message):
            FileHandle.standardError.write(Data("MSub CLI error: \(message)\n\n\(helpText)".utf8))
            Darwin.exit(64)
        }
    }

    static var launchCommands: [MSubAutomationCommand] {
        if case .commands(let commands) = launchParseResult {
            return commands
        }
        return []
    }

    static func commands(from url: URL) -> [MSubAutomationCommand] {
        guard url.scheme?.lowercased() == "msub" else { return [] }
        var commands: [MSubAutomationCommand] = []
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = (url.host ?? components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "")
            .lowercased()
        let queryItems = components?.queryItems ?? []

        func values(_ name: String) -> [String] {
            queryItems.compactMap { $0.name == name ? $0.value : nil }
        }

        for rawPath in values("path") + values("file") {
            commands.append(.open(fileURL(from: rawPath)))
        }

        switch action {
        case "open":
            break
        case "preview":
            commands.append(.preview)
        case "transcribe", "start":
            commands.append(.transcribe)
        case "stop":
            commands.append(.stop)
        case "save-all", "saveall", "save":
            commands.append(.saveAll)
        case "segments":
            commands.append(.showSegments)
        case "output":
            commands.append(.showOutput)
        case "cue-list", "cuelist", "list":
            commands.append(.showCueList)
        case "":
            break
        default:
            break
        }

        if truthy(values("preview").last) {
            commands.append(.preview)
        }
        if truthy(values("transcribe").last) || truthy(values("start").last) {
            commands.append(.transcribe)
        }
        if truthy(values("saveAll").last) || truthy(values("save-all").last) || truthy(values("save").last) {
            commands.append(.saveAll)
        }
        if truthy(values("stop").last) {
            commands.append(.stop)
        }
        if let tab = values("tab").last {
            commands.append(contentsOf: commandsForTab(tab))
        }
        if let rawLanguage = values("language").last, let language = AppLanguage(rawValue: rawLanguage) {
            commands.append(.setLanguage(language))
        }
        if let rawTheme = values("theme").last, let theme = AppearanceTheme(rawValue: rawTheme) {
            commands.append(.setTheme(theme))
        }

        return commands
    }

    private static func parse(arguments: [String]) -> ParseResult {
        guard !arguments.isEmpty else { return .none }
        var commands: [MSubAutomationCommand] = []
        var recognized = false
        var index = 0

        func nextValue(after option: String) -> String? {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else { return nil }
            let value = arguments[valueIndex]
            guard !value.hasPrefix("--") else { return nil }
            index = valueIndex
            return value
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .help
            case "--version":
                return .version
            case "-o", "--open":
                recognized = true
                guard let value = nextValue(after: argument) else {
                    return .error("Missing file path after \(argument).")
                }
                commands.append(.open(fileURL(from: value)))
            case "--preview":
                recognized = true
                commands.append(.preview)
            case "--transcribe", "--start":
                recognized = true
                commands.append(.transcribe)
            case "--stop":
                recognized = true
                commands.append(.stop)
            case "--save-all":
                recognized = true
                commands.append(.saveAll)
            case "--tab":
                recognized = true
                guard let value = nextValue(after: argument) else {
                    return .error("Missing tab name after \(argument).")
                }
                let tabCommands = commandsForTab(value)
                guard !tabCommands.isEmpty else {
                    return .error("Unknown tab '\(value)'. Use segments, output, or cue-list.")
                }
                commands.append(contentsOf: tabCommands)
            case "--language":
                recognized = true
                guard let value = nextValue(after: argument) else {
                    return .error("Missing language after \(argument).")
                }
                guard let language = AppLanguage(rawValue: value) else {
                    return .error("Unknown language '\(value)'. Use zh, zh-Hant, ja, or en.")
                }
                commands.append(.setLanguage(language))
            case "--theme":
                recognized = true
                guard let value = nextValue(after: argument) else {
                    return .error("Missing theme after \(argument).")
                }
                guard let theme = AppearanceTheme(rawValue: value) else {
                    return .error("Unknown theme '\(value)'. Use system, light, or dark.")
                }
                commands.append(.setTheme(theme))
            default:
                if argument.hasPrefix("-") {
                    if recognized {
                        return .error("Unknown option '\(argument)'.")
                    }
                    if shouldSkipCocoaArgumentValue(argument),
                       index + 1 < arguments.count,
                       !arguments[index + 1].hasPrefix("-") {
                        index += 1
                    }
                } else {
                    commands.append(.open(fileURL(from: argument)))
                }
            }
            index += 1
        }

        return commands.isEmpty ? .none : .commands(commands)
    }

    private static func shouldSkipCocoaArgumentValue(_ argument: String) -> Bool {
        argument.hasPrefix("-NS")
            || argument.hasPrefix("-Apple")
            || argument.hasPrefix("-NST")
    }

    private static func fileURL(from rawValue: String) -> URL {
        if let url = URL(string: rawValue), url.isFileURL {
            return url.standardizedFileURL
        }
        let expanded = (rawValue as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }

    private static func commandsForTab(_ rawValue: String) -> [MSubAutomationCommand] {
        switch rawValue.lowercased() {
        case "segments", "segment":
            [.showSegments]
        case "output", "preview":
            [.showOutput]
        case "cue-list", "cuelist", "list", "cues":
            [.showCueList]
        default:
            []
        }
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }

    private enum ParseResult: Sendable {
        case none
        case help
        case version
        case commands([MSubAutomationCommand])
        case error(String)
    }

    private static let helpText = """
    Usage:
      MSub [files...] [options]
      MSub --open <file> [--preview | --transcribe] [--save-all]
      open 'msub://open?path=/absolute/file.mp4&transcribe=1'

    Options:
      -o, --open <file>       Open a media or subtitle file in the app.
          --preview           Run segment preview for loaded files.
          --transcribe        Start transcription for loaded files.
          --stop              Stop the running job.
          --save-all          Save all generated or edited subtitles.
          --tab <name>        Show segments, output, or cue-list.
          --language <id>     Set UI language: zh, zh-Hant, ja, en.
          --theme <theme>     Set theme: system, light, dark.
      -h, --help              Show this help.

    URL control:
      msub://preview
      msub://transcribe
      msub://stop
      msub://save-all
      msub://show?tab=cue-list
      msub://open?path=/absolute/file.mp4&preview=1

    """
}

// MARK: - Preferences Window

struct PreferencesView: View {
    @Environment(TranscriptionSettings.self) private var settings
    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.systemDefault.rawValue
    @AppStorage("huz.appearanceTheme") private var appearanceRaw = AppearanceTheme.system.rawValue
    @State private var pendingRelaunchLanguage: AppLanguage?
    @State private var editingPresetID: UUID?
    @State private var editingPresetName = ""
    private let visibleASREngines: [ASREngine] = [.fireredasr2, .sensevoice, .mimo, .mega, .apple]
    private let visibleVADEngines: [VADEngine] = [.pyannoteMLX, .firered, .energy]

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .systemDefault
    }

    private func t(_ key: String) -> String { Copy.text(key, language: language) }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(t("prefs.general"), systemImage: "gearshape") }
            modelTab
                .tabItem { Label(t("prefs.model"), systemImage: "cube") }
            ModelManagerView(language: language)
                .tabItem { Label(t("prefs.modelManager"), systemImage: "arrow.down.circle") }
            presetsTab
                .tabItem { Label(t("prefs.presets"), systemImage: "slider.horizontal.3") }
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

    private var presetsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("prefs.customPresets"))
                .font(.headline)

            if settings.customPresets.isEmpty {
                Text(t("prefs.noCustomPresets"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(settings.customPresets) { preset in
                        HStack(spacing: 8) {
                            if editingPresetID == preset.id {
                                TextField("", text: $editingPresetName)
                                    .textFieldStyle(.roundedBorder)
                                Button(t("button.save")) {
                                    settings.renameCustomPreset(id: preset.id, to: editingPresetName)
                                    editingPresetID = nil
                                    editingPresetName = ""
                                }
                                .disabled(editingPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button(t("button.cancel")) {
                                    editingPresetID = nil
                                    editingPresetName = ""
                                }
                            } else {
                                Text(preset.name)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    editingPresetID = preset.id
                                    editingPresetName = preset.name
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help(t("prefs.renamePreset"))

                                Button(role: .destructive) {
                                    if editingPresetID == preset.id {
                                        editingPresetID = nil
                                        editingPresetName = ""
                                    }
                                    settings.deleteCustomPreset(id: preset.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help(t("prefs.deletePreset"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
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
    private var pendingAutomationCommands: [MSubAutomationCommand] = []
    private var didEnqueueLaunchCommands = false

    func enqueueOpenURL(_ url: URL) {
        pendingOpenURLs.append(url)
    }

    func takePendingOpenURLs() -> [URL] {
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        return urls
    }

    func enqueueAutomationCommands(_ commands: [MSubAutomationCommand]) {
        guard !commands.isEmpty else { return }
        pendingAutomationCommands.append(contentsOf: commands)
    }

    func enqueueLaunchCommandsIfNeeded() {
        guard !didEnqueueLaunchCommands else { return }
        didEnqueueLaunchCommands = true
        enqueueAutomationCommands(MSubCommandLine.launchCommands)
    }

    func submitAutomationCommands(_ commands: [MSubAutomationCommand]) {
        guard !commands.isEmpty else { return }
        if isReady {
            for command in commands {
                dispatch(command)
            }
        } else {
            enqueueAutomationCommands(commands)
        }
    }

    func flushPendingAutomation() {
        let openURLs = takePendingOpenURLs()
        for url in openURLs {
            dispatch(.open(url))
        }

        let commands = pendingAutomationCommands
        pendingAutomationCommands = []
        for command in commands {
            dispatch(command)
        }
    }

    private func dispatch(_ command: MSubAutomationCommand) {
        switch command {
        case .open(let url):
            NotificationCenter.default.post(name: .msubOpenRecentFileRequested, object: url)
        case .preview:
            NotificationCenter.default.post(name: .msubPreviewRequested, object: nil)
        case .transcribe:
            NotificationCenter.default.post(name: .msubTranscribeRequested, object: nil)
        case .stop:
            NotificationCenter.default.post(name: .msubStopRequested, object: nil)
        case .saveAll:
            NotificationCenter.default.post(name: .msubSaveAllRequested, object: nil)
        case .showSegments:
            NotificationCenter.default.post(name: .msubShowSegmentsTabRequested, object: nil)
        case .showOutput:
            NotificationCenter.default.post(name: .msubShowOutputTabRequested, object: nil)
        case .showCueList:
            NotificationCenter.default.post(name: .msubShowCueListTabRequested, object: nil)
        case .setLanguage(let language):
            _ = AppLanguageBootstrap.setLanguage(language)
        case .setTheme(let theme):
            UserDefaults.standard.set(theme.rawValue, forKey: "huz.appearanceTheme")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        BackendService.terminateRecordedBackendProcesses()
        MediaProcessingCleanup.cleanupBeforeTerminate()
    }

    // MARK: Undo fallback
    //
    // Cmd+Z travels the responder chain from the first responder. When an
    // action removes the focused view (e.g. deleting the selected cue row,
    // whose text editor was first responder), the window's first responder
    // resets and nothing in the chain implements undo:/redo: anymore — so
    // Edit > Undo goes dead even though the action was registered. The app
    // delegate sits at the end of the chain; forward to the key window's
    // undo manager (the same manager SwiftUI's environment provides).

    @MainActor
    @objc func undo(_ sender: Any?) {
        guard let undoManager = NSApp.keyWindow?.undoManager, undoManager.canUndo else {
            NSSound.beep()
            return
        }
        undoManager.undo()
    }

    @MainActor
    @objc func redo(_ sender: Any?) {
        guard let undoManager = NSApp.keyWindow?.undoManager, undoManager.canRedo else {
            NSSound.beep()
            return
        }
        undoManager.redo()
    }

    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return NSApp.keyWindow?.undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            return NSApp.keyWindow?.undoManager?.canRedo ?? false
        default:
            return true
        }
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let raw = UserDefaults.standard.string(forKey: "huz.uiLanguage") ?? AppLanguage.systemDefault.rawValue
        let language = AppLanguage(rawValue: raw) ?? .systemDefault
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
        var controlCommands: [MSubAutomationCommand] = []
        var fileURLs: [URL] = []
        for url in urls {
            let commands = MSubCommandLine.commands(from: url)
            if commands.isEmpty {
                fileURLs.append(url)
            } else {
                controlCommands.append(contentsOf: commands)
            }
        }

        if !fileURLs.isEmpty {
            let openCommands = fileURLs.map(MSubAutomationCommand.open)
            DockMenuState.shared.submitAutomationCommands(openCommands)
        }
        if !controlCommands.isEmpty {
            DockMenuState.shared.submitAutomationCommands(controlCommands)
        }
    }

    @MainActor
    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DockMenuState.shared.submitAutomationCommands([.open(url)])
    }
}
