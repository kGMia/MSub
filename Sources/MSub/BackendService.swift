import Darwin
import Foundation
import CryptoKit
import Observation
import AppKit

private struct BackendManifest: Decodable {
    let sourceModelPath: String?
    let sourceSenseVoiceModelPath: String?
    let sourceMiMoModelPath: String?
    let sourceMiMoTokenizerPath: String?
    let sourceFireRedVADModelPath: String?
    let sourceDiarizationModelPath: String?
    let sourceSpeakerRecognitionModelPath: String?
    let sourceEmotionModelPath: String?
}

@MainActor
@Observable
final class BackendService {
    var isRunning = false
    var message = "Backend stopped"
    var lastLog = ""
    var baseURL = URL(string: "http://127.0.0.1:7860")!

    private enum MissingModelAction {
        case chooseLocal
        case download
        case cancel
    }

    private var process: Process?
    private var pipe: Pipe?
    private var recentLog = ""
    private let maxRecentLogLength = 6_000
    private var declinedSourceModelFolders = Set<String>()
    private var blockedStartupMessage: String?
    private let fireRedModelDirectoryName = "FireRedASR2-AED-mlx"
    private let fireRedRemoteModelID = "mlx-community/FireRedASR2-AED-mlx"
    private let fireRedModelPathKey = "msub.modelPath.fireredasr2"
    private let fireRedModelDownloadConsentKey = "msub.modelDownloadConsent.fireredasr2"
    private let emotionModelDirectoryName = "emotion2vec_plus_base"
    private let emotionRemoteModelID = "emotion2vec/emotion2vec_plus_base"
    private let emotionModelPathKey = "msub.modelPath.emotion2vecPlusBase"
    private let emotionModelDownloadConsentKey = "msub.modelDownloadConsent.emotion2vecPlusBase"
    private let speakerRecognitionModelDirectoryName = "speech_eres2netv2_sv_zh-cn_16k-common"
    private let speakerRecognitionRemoteModelID = "iic/speech_eres2netv2_sv_zh-cn_16k-common"
    private let speakerRecognitionModelPathKey = "msub.modelPath.eres2netv2Speaker"
    private let speakerRecognitionModelDownloadConsentKey = "msub.modelDownloadConsent.eres2netv2Speaker"
    private static let recordedBackendProcessIDsKey = "msub.backendProcessIDs.v1"

    func start() {
        guard process == nil else { return }
        Self.terminateRecordedBackendProcesses()
        guard let workspace = findWorkspaceRoot() else {
            message = "Could not find MSub backend"
            return
        }

        guard let port = availablePort(startingAt: 7860) else {
            isRunning = false
            message = "Could not bind a local backend port. If you are running inside a restricted sandbox, launch the app from Xcode or Finder."
            return
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        recentLog = ""
        lastLog = ""
        blockedStartupMessage = nil
        message = "Starting backend at 127.0.0.1:\(port)"

        var environment = ProcessInfo.processInfo.environment
        let fallbackVenvURL = configureUVEnvironment(&environment, workspace: workspace)
        let resolvedFireRedModel = bundledOrWorkspaceModel(in: workspace)
        if let modelPath = resolvedFireRedModel {
            environment["MSUB_MODEL"] = modelPath.path
            environment["HUZ_MODEL"] = modelPath.path
        }
        if let blockedStartupMessage {
            isRunning = false
            message = blockedStartupMessage
            return
        }
        if UserDefaults.standard.bool(forKey: fireRedModelDownloadConsentKey) {
            environment["MSUB_ALLOW_MODEL_DOWNLOAD"] = "1"
            if resolvedFireRedModel == nil {
                environment["MSUB_MODEL"] = fireRedRemoteModelID
                environment["HUZ_MODEL"] = fireRedRemoteModelID
            }
        }
        if let senseVoiceModelPath = bundledOrWorkspaceSenseVoiceModel(in: workspace, allowAuthorizationPrompt: false) {
            environment["MSUB_SENSEVOICE_MODEL"] = senseVoiceModelPath.path
        }
        if let mimoModelPath = bundledOrWorkspaceMiMoModel(in: workspace, allowAuthorizationPrompt: false) {
            environment["MSUB_MIMO_MODEL"] = mimoModelPath.path
        }
        if let diarizationModelPath = bundledOrWorkspaceDiarizationModel(in: workspace) {
            environment["MSUB_DIARIZATION_MODEL"] = diarizationModelPath.path
        }
        if let speakerRecognitionModelPath = bundledOrWorkspaceSpeakerRecognitionModel(in: workspace) {
            environment["MSUB_SPEAKER_RECOGNITION_MODEL"] = speakerRecognitionModelPath.path
        } else if UserDefaults.standard.bool(forKey: speakerRecognitionModelDownloadConsentKey) {
            environment["MSUB_SPEAKER_RECOGNITION_MODEL"] = speakerRecognitionRemoteModelID
        }
        if let emotionModelPath = bundledOrWorkspaceEmotionModel(in: workspace) {
            environment["MSUB_EMOTION_MODEL"] = emotionModelPath.path
        } else if UserDefaults.standard.bool(forKey: emotionModelDownloadConsentKey) {
            environment["MSUB_EMOTION_MODEL"] = emotionRemoteModelID
        }
        if let fireRedVADModelPath = bundledOrWorkspaceFireRedVADModel(in: workspace) {
            environment["MSUB_FIRERED_VAD_MODEL"] = fireRedVADModelPath.path
        }
        environment["MSUB_HOST"] = "127.0.0.1"
        environment["MSUB_PORT"] = "\(port)"
        environment["MSUB_BACKEND_ROOT"] = workspace.path
        environment["MSUB_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
        environment["MSUB_MODEL_IDLE_SECONDS"] = environment["MSUB_MODEL_IDLE_SECONDS"] ?? "60"
        environment["MSUB_STT_MODEL_CACHE_SIZE"] = environment["MSUB_STT_MODEL_CACHE_SIZE"] ?? "1"
        environment["MSUB_CLEAR_MLX_CACHE_EACH_CHUNK"] = environment["MSUB_CLEAR_MLX_CACHE_EACH_CHUNK"] ?? "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["UV_NO_PROGRESS"] = "1"
        environment["UV_LINK_MODE"] = "copy"
        configureJobDirectory(&environment, workspace: workspace)
        configurePythonPath(&environment, workspace: workspace)
        configureBundledMediaTools(&environment)
        configureModelDownloadEnvironment(&environment)
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PATH"] = [
            environment["PATH"],
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        ]
        .compactMap { $0 }
        .joined(separator: ":")

        let process = Process()
        process.currentDirectoryURL = workspace
        if let python = usablePython(workspace: workspace, fallbackVenvURL: fallbackVenvURL, environment: environment) {
            process.executableURL = python.url
            process.arguments = ["-m", "huz_subtitle.web"]
            appendLog("Starting backend with \(python.label): \(python.url.path)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "uv",
                "run",
                "--extra",
                "speaker",
                "--extra",
                "emotion",
                "msub-web",
            ]
            appendLog("Starting backend with uv run --extra speaker --extra emotion msub-web")
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.appendLog(trimmed)
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.pipe?.fileHandleForReading.readabilityHandler = nil
                self?.pipe = nil
                self?.process = nil
                self?.isRunning = false
                self?.forgetBackendProcess(process.processIdentifier)
                self?.message = self?.stoppedMessage(exitCode: process.terminationStatus) ?? "Backend stopped"
            }
        }

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
            recordBackendProcess(process.processIdentifier)
            isRunning = true
            message = "Backend running at 127.0.0.1:\(port)"
        } catch {
            message = error.localizedDescription
        }
    }

    func ensureRunning(timeout: TimeInterval = 25.0) async -> Bool {
        let expectedBackendRootPath = expectedBackendRootPath()
        let expectedModelPath = expectedModelPath()
        let expectedSenseVoiceModelPath = expectedSenseVoiceModelPath()
        let expectedMiMoModelPath = expectedMiMoModelPath()
        let expectedBackendFingerprint = expectedBackendSourceFingerprint()
        if await healthCheck(
            url: baseURL,
            expectedBackendRootPath: expectedBackendRootPath,
            expectedModelPath: expectedModelPath,
            expectedSenseVoiceModelPath: expectedSenseVoiceModelPath,
            expectedMiMoModelPath: expectedMiMoModelPath,
            expectedBackendFingerprint: expectedBackendFingerprint
        ) {
            isRunning = true
            message = "Backend running at \(baseURL.host() ?? "127.0.0.1"):\(baseURL.port ?? 7860)"
            return true
        }
        if process != nil {
            appendLog("Restarting stale backend")
            stop(waitForExit: true)
        }
        if process == nil {
            start()
        }
        guard isRunning else { return false }
        return await waitUntilHealthy(timeout: timeout)
    }

    func waitUntilHealthy(timeout: TimeInterval = 4.0) async -> Bool {
        let expectedBackendRootPath = expectedBackendRootPath()
        let expectedModelPath = expectedModelPath()
        let expectedSenseVoiceModelPath = expectedSenseVoiceModelPath()
        let expectedMiMoModelPath = expectedMiMoModelPath()
        let expectedBackendFingerprint = expectedBackendSourceFingerprint()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await healthCheck(
                url: baseURL,
                expectedBackendRootPath: expectedBackendRootPath,
                expectedModelPath: expectedModelPath,
                expectedSenseVoiceModelPath: expectedSenseVoiceModelPath,
                expectedMiMoModelPath: expectedMiMoModelPath,
                expectedBackendFingerprint: expectedBackendFingerprint
            ) {
                return true
            }
            if process == nil {
                return false
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    func stop(waitForExit: Bool = false) {
        requestBackendShutdown(waitForResponse: waitForExit)
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        let runningProcess = process
        process = nil
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminationHandler = nil
            runningProcess.terminate()
            let pid = runningProcess.processIdentifier
            if waitForExit {
                Self.waitForBackendExit(runningProcess, pid: pid)
            } else {
                DispatchQueue.global(qos: .utility).async {
                    Self.waitForBackendExit(runningProcess, pid: pid)
                }
            }
            forgetBackendProcess(pid)
        }
        isRunning = false
        message = "Backend stopped"
    }

    private func recordBackendProcess(_ pid: pid_t) {
        var ids = Set(UserDefaults.standard.array(forKey: Self.recordedBackendProcessIDsKey) as? [Int] ?? [])
        ids.insert(Int(pid))
        UserDefaults.standard.set(Array(ids), forKey: Self.recordedBackendProcessIDsKey)
    }

    private func forgetBackendProcess(_ pid: pid_t) {
        var ids = Set(UserDefaults.standard.array(forKey: Self.recordedBackendProcessIDsKey) as? [Int] ?? [])
        ids.remove(Int(pid))
        UserDefaults.standard.set(Array(ids), forKey: Self.recordedBackendProcessIDsKey)
    }

    static func terminateRecordedBackendProcesses(excluding excluded: Set<pid_t> = []) {
        let ids = UserDefaults.standard.array(forKey: recordedBackendProcessIDsKey) as? [Int] ?? []
        var survivors: [Int] = []
        for rawPID in ids {
            let pid = pid_t(rawPID)
            if excluded.contains(pid) {
                survivors.append(rawPID)
                continue
            }
            guard isProcessAlive(pid) else {
                continue
            }
            guard isLikelyMSubBackendProcess(pid) else {
                survivors.append(rawPID)
                continue
            }
            terminateProcess(pid)
        }
        UserDefaults.standard.set(survivors, forKey: recordedBackendProcessIDsKey)
    }

    private nonisolated static func waitForBackendExit(_ process: Process, pid: pid_t) {
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
    }

    private nonisolated static func isProcessAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private nonisolated static func terminateProcess(_ pid: pid_t) {
        guard isProcessAlive(pid) else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2.0)
        while isProcessAlive(pid) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isProcessAlive(pid) {
            kill(pid, SIGKILL)
        }
    }

    private nonisolated static func isLikelyMSubBackendProcess(_ pid: pid_t) -> Bool {
        if let path = executablePath(for: pid),
           path.contains("/MSub.app/Contents/Resources/backend/") {
            return true
        }
        guard let command = commandLine(for: pid) else { return false }
        return command.contains("huz_subtitle.web") || command.contains("msub-web")
    }

    private nonisolated static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func commandLine(for pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func memoryUsageBytes() -> UInt64? {
        guard let pid = process?.processIdentifier, pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result > 0 else { return nil }
        return info.pti_resident_size
    }

    func rememberEmotionModelDirectory(_ url: URL) {
        rememberAuxiliaryModelDirectory(
            url,
            pathKey: emotionModelPathKey,
            downloadConsentKey: emotionModelDownloadConsentKey
        )
    }

    func useRemoteEmotionModelDownload() {
        useRemoteAuxiliaryModel(
            pathKey: emotionModelPathKey,
            downloadConsentKey: emotionModelDownloadConsentKey
        )
    }

    func rememberSpeakerRecognitionModelDirectory(_ url: URL) {
        rememberAuxiliaryModelDirectory(
            url,
            pathKey: speakerRecognitionModelPathKey,
            downloadConsentKey: speakerRecognitionModelDownloadConsentKey
        )
    }

    func useRemoteSpeakerRecognitionModelDownload() {
        useRemoteAuxiliaryModel(
            pathKey: speakerRecognitionModelPathKey,
            downloadConsentKey: speakerRecognitionModelDownloadConsentKey
        )
    }

    private func requestBackendShutdown(waitForResponse: Bool = false) {
        var request = URLRequest(url: baseURL.appending(path: "/api/shutdown"))
        request.httpMethod = "POST"
        request.timeoutInterval = waitForResponse ? 1.0 : 0.5
        if waitForResponse {
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in
                semaphore.signal()
            }
            .resume()
            _ = semaphore.wait(timeout: .now() + 1.0)
        } else {
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    private func healthCheck(
        url baseURL: URL,
        expectedBackendRootPath: String?,
        expectedModelPath: String?,
        expectedSenseVoiceModelPath: String?,
        expectedMiMoModelPath: String?,
        expectedBackendFingerprint: String?
    ) async -> Bool {
        do {
            let url = baseURL.appending(path: "/api/health")
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200..<300).contains(http.statusCode) else { return false }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let expectedBackendRootPath {
                guard let object,
                      let backendRoot = object["backendRoot"] as? String,
                      pathsReferToSameFile(backendRoot, expectedBackendRootPath) else {
                    return false
                }
            }
            if let expectedBackendFingerprint {
                guard let object,
                      let backendFingerprint = object["backendSourceFingerprint"] as? String,
                      backendFingerprint == expectedBackendFingerprint else {
                    return false
                }
            }
            return await configMatchesExpectedModels(
                baseURL: baseURL,
                expectedModelPath: expectedModelPath,
                expectedSenseVoiceModelPath: expectedSenseVoiceModelPath,
                expectedMiMoModelPath: expectedMiMoModelPath
            )
        } catch {
            return false
        }
    }

    private func configMatchesExpectedModels(
        baseURL: URL,
        expectedModelPath: String?,
        expectedSenseVoiceModelPath: String?,
        expectedMiMoModelPath: String?
    ) async -> Bool {
        guard expectedModelPath != nil || expectedSenseVoiceModelPath != nil || expectedMiMoModelPath != nil else { return true }
        do {
            let url = baseURL.appending(path: "/api/config")
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            if let expectedModelPath {
                guard let defaultModel = object["defaultModel"] as? String,
                      pathsReferToSameFile(defaultModel, expectedModelPath) else {
                    return false
                }
            }
            if let expectedMiMoModelPath {
                guard let models = object["models"] as? [[String: Any]],
                      let mimo = models.first(where: { ($0["engine"] as? String) == "mimo" }),
                      let defaultModel = mimo["defaultModel"] as? String,
                      pathsReferToSameFile(defaultModel, expectedMiMoModelPath) else {
                    return false
                }
            }
            if let expectedSenseVoiceModelPath {
                guard let models = object["models"] as? [[String: Any]],
                      let senseVoice = models.first(where: { ($0["engine"] as? String) == "sensevoice" }),
                      let defaultModel = senseVoice["defaultModel"] as? String,
                      pathsReferToSameFile(defaultModel, expectedSenseVoiceModelPath) else {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func pathsReferToSameFile(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return left == right
    }

    private func expectedModelPath() -> String? {
        guard let workspace = findWorkspaceRoot(),
              let modelURL = bundledOrWorkspaceModel(in: workspace, allowAuthorizationPrompt: false) else {
            return nil
        }
        return modelURL.standardizedFileURL.path
    }

    private func expectedMiMoModelPath() -> String? {
        guard let workspace = findWorkspaceRoot(),
              let modelURL = bundledOrWorkspaceMiMoModel(in: workspace, allowAuthorizationPrompt: false) else {
            return nil
        }
        return modelURL.standardizedFileURL.path
    }

    private func expectedSenseVoiceModelPath() -> String? {
        guard let workspace = findWorkspaceRoot(),
              let modelURL = bundledOrWorkspaceSenseVoiceModel(in: workspace, allowAuthorizationPrompt: false) else {
            return nil
        }
        return modelURL.standardizedFileURL.path
    }

    private func expectedBackendRootPath() -> String? {
        findWorkspaceRoot()?.standardizedFileURL.path
    }

    private func expectedBackendSourceFingerprint() -> String? {
        guard let workspace = findWorkspaceRoot() else { return nil }
        let files = [
            workspace.appending(path: "src/huz_subtitle/cli.py"),
            workspace.appending(path: "src/huz_subtitle/web.py"),
        ]
        var digest = SHA256()
        for file in files {
            guard let data = try? Data(contentsOf: file) else { return nil }
            digest.update(data: Data(file.lastPathComponent.utf8))
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func findWorkspaceRoot() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["MSUB_WORKSPACE"]
            ?? ProcessInfo.processInfo.environment["HUZ_WORKSPACE"] {
            let url = URL(fileURLWithPath: envPath)
            if isBackendRoot(url) {
                return url
            }
        }

        var candidates: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent())
        }

        for candidate in candidates {
            var cursor = candidate
            for _ in 0..<8 {
                if isBackendRoot(cursor) {
                    return cursor
                }
                cursor.deleteLastPathComponent()
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundledBackend = resourceURL.appending(path: "backend")
            if isBackendRoot(bundledBackend) {
                return bundledBackend
            }
        }

        return nil
    }

    private func isBackendRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "pyproject.toml").path)
            && FileManager.default.fileExists(atPath: url.appending(path: "src/huz_subtitle/web.py").path)
    }

    private func configureJobDirectory(_ environment: inout [String: String], workspace: URL) {
        if isBundledBackend(workspace),
           let jobsURL = appStorageURL(directory: .applicationSupportDirectory, leaf: "web-jobs") {
            environment["MSUB_JOB_DIR"] = jobsURL.path
        }
    }

    private func configurePythonPath(_ environment: inout [String: String], workspace: URL) {
        var pythonPaths = [workspace.appending(path: "src").path]
        if let bundledSitePackages = sitePackages(in: workspace.appending(path: ".venv")) {
            pythonPaths.append(bundledSitePackages.path)
        }

        let srcPath = pythonPaths.joined(separator: ":")
        if let existing = environment["PYTHONPATH"], !existing.isEmpty {
            environment["PYTHONPATH"] = "\(srcPath):\(existing)"
        } else {
            environment["PYTHONPATH"] = srcPath
        }
    }

    private func configureBundledMediaTools(_ environment: inout [String: String]) {
        var toolDirectories: [String] = []
        if let ffmpeg = bundledExecutable(named: "ffmpeg") {
            environment["MSUB_FFMPEG"] = ffmpeg.path
            toolDirectories.append(ffmpeg.deletingLastPathComponent().path)
            appendLog("Using bundled ffmpeg: \(ffmpeg.path)")
        }
        if let ffprobe = bundledExecutable(named: "ffprobe") {
            environment["MSUB_FFPROBE"] = ffprobe.path
            toolDirectories.append(ffprobe.deletingLastPathComponent().path)
        }
        guard !toolDirectories.isEmpty else { return }
        let existingPath = environment["PATH"]
        environment["PATH"] = (toolDirectories + [existingPath])
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }

    private func configureModelDownloadEnvironment(_ environment: inout [String: String]) {
        guard isBundledRuntimeLaunch(),
              let hfHome = appStorageURL(directory: .cachesDirectory, leaf: "huggingface") else {
            return
        }
        let hubCache = hfHome.appending(path: "hub")
        try? FileManager.default.createDirectory(at: hubCache, withIntermediateDirectories: true)
        environment["HF_HOME"] = hfHome.path
        environment["HUGGINGFACE_HUB_CACHE"] = hubCache.path
        if let modelscopeHome = appStorageURL(directory: .cachesDirectory, leaf: "modelscope") {
            environment["MODELSCOPE_CACHE"] = modelscopeHome.path
            environment["MODELSCOPE_HOME"] = modelscopeHome.path
        }
    }

    private func isBundledRuntimeLaunch() -> Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        return isBackendRoot(resourceURL.appending(path: "backend"))
    }

    private func bundledExecutable(named name: String) -> URL? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        let path = url.path
        if !FileManager.default.isExecutableFile(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return FileManager.default.isExecutableFile(atPath: path) ? url : nil
    }

    private func configureUVEnvironment(_ environment: inout [String: String], workspace: URL) -> URL? {
        if isBundledBackend(workspace) {
            var venvURL: URL?
            if let cacheURL = appStorageURL(directory: .cachesDirectory, leaf: "uv-cache") {
                environment["UV_CACHE_DIR"] = cacheURL.path
            }
            if let appVenvURL = appStorageURL(directory: .applicationSupportDirectory, leaf: "backend-venv") {
                environment["UV_PROJECT_ENVIRONMENT"] = appVenvURL.path
                venvURL = appVenvURL
            }
            return venvURL
        } else {
            environment["UV_CACHE_DIR"] = ".uv-cache"
            let venvURL = workspace.appending(path: ".venv")
            return FileManager.default.fileExists(atPath: venvURL.path) ? venvURL : nil
        }
    }

    private func usablePython(
        workspace: URL,
        fallbackVenvURL: URL?,
        environment: [String: String]
    ) -> (url: URL, label: String)? {
        var candidates: [(url: URL, label: String)] = []
        var seen = Set<String>()

        func appendCandidate(_ url: URL, label: String) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            candidates.append((url, label))
        }

        if isBundledBackend(workspace) {
            appendCandidate(workspace.appending(path: ".venv/bin/python"), label: "bundled backend venv")
        }
        if isBundledBackend(workspace), let runtimePython = bundledRuntimePython(in: workspace) {
            appendCandidate(runtimePython, label: "bundled Python runtime")
        }
        if let fallbackVenvURL {
            appendCandidate(fallbackVenvURL.appending(path: "bin/python"), label: "backend venv")
        }

        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.url.path) else { continue }
            if pythonHasBackendDependencies(candidate.url, environment: environment) {
                return candidate
            }
            appendLog("Skipping \(candidate.label); backend dependencies are incomplete.")
        }
        return nil
    }

    private func bundledRuntimePython(in workspace: URL) -> URL? {
        let binURL = workspace.appending(path: "python/bin")
        for name in ["python3.12", "python3", "python"] {
            let candidate = binURL.appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func sitePackages(in venvURL: URL) -> URL? {
        let libURL = venvURL.appending(path: "lib")
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: libURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return versions
            .map { $0.appending(path: "site-packages") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func pythonHasBackendDependencies(_ pythonURL: URL, environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", "import fastapi, uvicorn, multipart"]
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isBundledBackend(_ workspace: URL) -> Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        return workspace.standardizedFileURL.path.hasPrefix(resourceURL.standardizedFileURL.path)
    }

    private func appStorageURL(directory: FileManager.SearchPathDirectory, leaf: String) -> URL? {
        guard let base = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            return nil
        }
        let url = base.appending(path: "MSub").appending(path: leaf)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            lastLog = error.localizedDescription
            return nil
        }
    }

    private func bundledOrWorkspaceModel(in workspace: URL, allowAuthorizationPrompt: Bool = true) -> URL? {
        for key in ["MSUB_MODEL", "HUZ_MODEL"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                let modelURL = URL(fileURLWithPath: value).standardizedFileURL
                if isValidModelDirectory(modelURL) {
                    return modelURL
                }
            }
        }

        if let savedModel = persistedModelDirectory(pathKey: fireRedModelPathKey) {
            return savedModel
        }

        let modelPath = workspace.appending(path: "models/\(fireRedModelDirectoryName)")
        if isValidModelDirectory(modelPath) {
            return modelPath
        }
        if !isBundledBackend(workspace),
           let authorizedModelPath = authorizedSourceModelDirectory(
               modelPath,
               displayName: "FireRedASR2-AED MLX",
               allowPrompt: allowAuthorizationPrompt,
               expectedDirectoryName: fireRedModelDirectoryName,
               persistedPathKey: fireRedModelPathKey,
               downloadConsentKey: fireRedModelDownloadConsentKey,
               remoteModelID: fireRedRemoteModelID
           ) {
            return authorizedModelPath
        }

        if isBundledBackend(workspace),
           let sourceModelPath = sourceModelPathFromManifest(in: workspace),
           let authorizedModelPath = authorizedSourceModelDirectory(
               sourceModelPath,
               displayName: "FireRedASR2-AED MLX",
               allowPrompt: allowAuthorizationPrompt,
               expectedDirectoryName: fireRedModelDirectoryName,
               persistedPathKey: fireRedModelPathKey,
               downloadConsentKey: fireRedModelDownloadConsentKey,
               remoteModelID: fireRedRemoteModelID
           ) {
            return authorizedModelPath
        }

        if let appSupportModel = appSupportModelDirectory(named: fireRedModelDirectoryName) {
            if isValidModelDirectory(appSupportModel) {
                return appSupportModel
            }
            if let chosenModel = resolveMissingRequiredModel(
                candidateURL: appSupportModel,
                displayName: "FireRedASR2-AED MLX",
                expectedDirectoryName: fireRedModelDirectoryName,
                persistedPathKey: fireRedModelPathKey,
                downloadConsentKey: fireRedModelDownloadConsentKey,
                remoteModelID: fireRedRemoteModelID,
                allowPrompt: allowAuthorizationPrompt
            ) {
                return chosenModel
            }
        }

        return nil
    }

    private func bundledOrWorkspaceMiMoModel(in workspace: URL, allowAuthorizationPrompt: Bool = true) -> URL? {
        if let value = ProcessInfo.processInfo.environment["MSUB_MIMO_MODEL"], !value.isEmpty {
            let modelURL = URL(fileURLWithPath: value).standardizedFileURL
            if isValidModelDirectory(modelURL) {
                return modelURL
            }
        }

        let modelPath = workspace.appending(path: "models/MiMo-V2.5-ASR-MLX-4bit")
        if isValidModelDirectory(modelPath), isValidMiMoTokenizerBeside(modelPath) {
            return modelPath
        }
        if !isBundledBackend(workspace),
           let authorizedModelPath = authorizedSourceModelDirectory(
               modelPath,
               displayName: "MiMo-V2.5-ASR MLX",
               allowPrompt: allowAuthorizationPrompt
           ),
           isValidMiMoTokenizerBeside(authorizedModelPath) {
            return authorizedModelPath
        }

        if isBundledBackend(workspace),
           let sourceModelPath = sourceMiMoModelPathFromManifest(in: workspace),
           let authorizedModelPath = authorizedSourceModelDirectory(
               sourceModelPath,
               displayName: "MiMo-V2.5-ASR MLX",
               allowPrompt: allowAuthorizationPrompt
           ),
           isValidMiMoTokenizerPathFromManifest(in: workspace, modelURL: sourceModelPath) {
            return authorizedModelPath
        }

        return nil
    }

    private func bundledOrWorkspaceSenseVoiceModel(in workspace: URL, allowAuthorizationPrompt: Bool = true) -> URL? {
        if let value = ProcessInfo.processInfo.environment["MSUB_SENSEVOICE_MODEL"], !value.isEmpty {
            let modelURL = URL(fileURLWithPath: value).standardizedFileURL
            if isValidModelDirectory(modelURL) {
                return modelURL
            }
        }

        let modelPath = workspace.appending(path: "models/SenseVoiceSmall")
        if isValidModelDirectory(modelPath) {
            return modelPath
        }
        if !isBundledBackend(workspace),
           let authorizedModelPath = authorizedSourceModelDirectory(
               modelPath,
               displayName: "SenseVoiceSmall MLX",
               allowPrompt: allowAuthorizationPrompt
           ) {
            return authorizedModelPath
        }

        if isBundledBackend(workspace),
           let sourceModelPath = sourceSenseVoiceModelPathFromManifest(in: workspace),
           let authorizedModelPath = authorizedSourceModelDirectory(
               sourceModelPath,
               displayName: "SenseVoiceSmall MLX",
               allowPrompt: allowAuthorizationPrompt
           ) {
            return authorizedModelPath
        }

        return nil
    }

    private func bundledOrWorkspaceDiarizationModel(in workspace: URL) -> URL? {
        for key in ["MSUB_DIARIZATION_MODEL", "PYANNOTE_MODEL"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                let modelURL = URL(fileURLWithPath: value).standardizedFileURL
                if isValidDiarizationModelDirectory(modelURL) {
                    return modelURL
                }
            }
        }

        let modelPath = workspace.appending(path: "models/pyannote-speaker-diarization-community-1")
        if isValidDiarizationModelDirectory(modelPath) {
            return modelPath
        }

        if isBundledBackend(workspace),
           let sourceModelPath = sourceDiarizationModelPathFromManifest(in: workspace),
           isValidDiarizationModelDirectory(sourceModelPath) {
            return sourceModelPath
        }

        return nil
    }

    private func bundledOrWorkspaceSpeakerRecognitionModel(in workspace: URL) -> URL? {
        bundledOrWorkspaceAuxiliaryModel(
            in: workspace,
            environmentKey: "MSUB_SPEAKER_RECOGNITION_MODEL",
            modelDirectoryName: speakerRecognitionModelDirectoryName,
            manifestPath: sourceSpeakerRecognitionModelPathFromManifest(in: workspace),
            persistedPathKey: speakerRecognitionModelPathKey,
            validator: isValidSpeakerRecognitionModelDirectory
        )
    }

    private func bundledOrWorkspaceEmotionModel(in workspace: URL) -> URL? {
        bundledOrWorkspaceAuxiliaryModel(
            in: workspace,
            environmentKey: "MSUB_EMOTION_MODEL",
            modelDirectoryName: emotionModelDirectoryName,
            manifestPath: sourceEmotionModelPathFromManifest(in: workspace),
            persistedPathKey: emotionModelPathKey,
            validator: isValidEmotionModelDirectory
        )
    }

    private func bundledOrWorkspaceAuxiliaryModel(
        in workspace: URL,
        environmentKey: String,
        modelDirectoryName: String,
        manifestPath: URL?,
        persistedPathKey: String,
        validator: (URL) -> Bool
    ) -> URL? {
        if let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty {
            let modelURL = URL(fileURLWithPath: value).standardizedFileURL
            if validator(modelURL) {
                return modelURL
            }
        }

        if let savedModel = persistedAuxiliaryModelDirectory(
            pathKey: persistedPathKey,
            validator: validator
        ) {
            return savedModel
        }

        let modelPath = workspace.appending(path: "models/\(modelDirectoryName)")
        if validator(modelPath) {
            return modelPath
        }

        if isBundledBackend(workspace), let manifestPath, validator(manifestPath) {
            return manifestPath
        }

        if let appSupportModel = appSupportModelDirectory(named: modelDirectoryName),
           validator(appSupportModel) {
            return appSupportModel
        }

        return nil
    }

    private func bundledOrWorkspaceFireRedVADModel(in workspace: URL) -> URL? {
        if let value = ProcessInfo.processInfo.environment["MSUB_FIRERED_VAD_MODEL"], !value.isEmpty {
            let modelURL = URL(fileURLWithPath: value).standardizedFileURL
            if isValidFireRedVADModelDirectory(modelURL) {
                return modelURL
            }
        }

        let modelPath = workspace.appending(path: "models/FireRedVAD")
        if isValidFireRedVADModelDirectory(modelPath) {
            return modelPath
        }

        if isBundledBackend(workspace),
           let sourceModelPath = sourceFireRedVADModelPathFromManifest(in: workspace),
           isValidFireRedVADModelDirectory(sourceModelPath) {
            return sourceModelPath
        }

        return nil
    }

    private func persistedModelDirectory(pathKey: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: pathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        _ = FolderAuthorizationStore.shared
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if isValidModelDirectory(url) {
            return url
        }
        UserDefaults.standard.removeObject(forKey: pathKey)
        return nil
    }

    private func persistedAuxiliaryModelDirectory(
        pathKey: String,
        validator: (URL) -> Bool
    ) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: pathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        _ = FolderAuthorizationStore.shared
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if validator(url) {
            return url
        }
        UserDefaults.standard.removeObject(forKey: pathKey)
        return nil
    }

    private func rememberAuxiliaryModelDirectory(
        _ url: URL,
        pathKey: String,
        downloadConsentKey: String
    ) {
        let standardized = url.standardizedFileURL
        FolderAuthorizationStore.shared.authorizeFolder(standardized)
        UserDefaults.standard.set(standardized.path, forKey: pathKey)
        UserDefaults.standard.set(false, forKey: downloadConsentKey)
        appendLog("Using user-selected auxiliary model: \(standardized.path)")
    }

    private func useRemoteAuxiliaryModel(pathKey: String, downloadConsentKey: String) {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.set(true, forKey: downloadConsentKey)
        appendLog("Using remote auxiliary model download/cache.")
    }

    private func appSupportModelDirectory(named name: String) -> URL? {
        appStorageURL(directory: .applicationSupportDirectory, leaf: "models")?.appending(path: name)
    }

    private func authorizedSourceModelDirectory(
        _ url: URL,
        displayName: String,
        allowPrompt: Bool,
        expectedDirectoryName: String? = nil,
        persistedPathKey: String? = nil,
        downloadConsentKey: String? = nil,
        remoteModelID: String? = nil
    ) -> URL? {
        let standardized = url.standardizedFileURL
        let authorizationStore = FolderAuthorizationStore.shared
        if isValidModelDirectory(standardized) {
            if let persistedPathKey {
                UserDefaults.standard.set(standardized.path, forKey: persistedPathKey)
            }
            return standardized
        }
        guard allowPrompt else { return nil }

        if let expectedDirectoryName,
           let persistedPathKey,
           let downloadConsentKey,
           let remoteModelID {
            return resolveMissingRequiredModel(
                candidateURL: standardized,
                displayName: displayName,
                expectedDirectoryName: expectedDirectoryName,
                persistedPathKey: persistedPathKey,
                downloadConsentKey: downloadConsentKey,
                remoteModelID: remoteModelID,
                allowPrompt: allowPrompt
            )
        }

        let folderURL = standardized.deletingLastPathComponent()
        let folderPath = folderURL.standardizedFileURL.path
        guard !declinedSourceModelFolders.contains(folderPath) else { return nil }

        let message = sourceModelAuthorizationMessage(displayName: displayName, folderURL: folderURL)
        let granted = authorizationStore.promptForFolderAuthorization(
            initialURL: standardized,
            message: message,
            prompt: sourceModelAuthorizationPrompt()
        )
        guard granted else {
            declinedSourceModelFolders.insert(folderPath)
            appendLog("Local \(displayName) model is not authorized: \(standardized.path)")
            return nil
        }

        if isValidModelDirectory(standardized) {
            appendLog("Using authorized local \(displayName) model: \(standardized.path)")
            return standardized
        }

        appendLog("Authorized folder does not expose a valid \(displayName) model: \(standardized.path)")
        return nil
    }

    private func resolveMissingRequiredModel(
        candidateURL: URL,
        displayName: String,
        expectedDirectoryName: String,
        persistedPathKey: String,
        downloadConsentKey: String,
        remoteModelID: String,
        allowPrompt: Bool
    ) -> URL? {
        guard allowPrompt, blockedStartupMessage == nil else { return nil }
        if UserDefaults.standard.bool(forKey: downloadConsentKey) {
            return nil
        }

        switch promptForMissingRequiredModelAction(
            displayName: displayName,
            expectedDirectoryName: expectedDirectoryName,
            remoteModelID: remoteModelID
        ) {
        case .chooseLocal:
            if let selectedModel = promptForLocalModelDirectory(
                candidateURL: candidateURL,
                displayName: displayName,
                expectedDirectoryName: expectedDirectoryName
            ) {
                UserDefaults.standard.set(selectedModel.path, forKey: persistedPathKey)
                UserDefaults.standard.set(false, forKey: downloadConsentKey)
                appendLog("Using user-selected local \(displayName) model: \(selectedModel.path)")
                return selectedModel
            }
            if blockedStartupMessage == nil {
                blockedStartupMessage = missingModelBlockedMessage(displayName: displayName)
            }
            appendLog("Missing required \(displayName) model; startup is blocked until the user chooses a model or allows download.")
            return nil
        case .download:
            UserDefaults.standard.removeObject(forKey: persistedPathKey)
            UserDefaults.standard.set(true, forKey: downloadConsentKey)
            appendLog("User allowed \(displayName) download from \(remoteModelID)")
            return nil
        case .cancel:
            blockedStartupMessage = missingModelBlockedMessage(displayName: displayName)
            appendLog("Missing required \(displayName) model; user cancelled model selection.")
            return nil
        }
    }

    private func promptForMissingRequiredModelAction(
        displayName: String,
        expectedDirectoryName: String,
        remoteModelID: String
    ) -> MissingModelAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = missingModelAlertTitle()
        alert.informativeText = missingModelAlertMessage(
            displayName: displayName,
            expectedDirectoryName: expectedDirectoryName,
            remoteModelID: remoteModelID
        )
        alert.addButton(withTitle: missingModelChooseButtonTitle())
        alert.addButton(withTitle: missingModelDownloadButtonTitle())
        alert.addButton(withTitle: cancelButtonTitle())

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .chooseLocal
        case .alertSecondButtonReturn:
            return .download
        default:
            return .cancel
        }
    }

    private func promptForLocalModelDirectory(
        candidateURL: URL,
        displayName: String,
        expectedDirectoryName: String
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = localModelPanelMessage(
            displayName: displayName,
            expectedDirectoryName: expectedDirectoryName
        )
        panel.prompt = missingModelChooseButtonTitle()
        panel.directoryURL = candidateURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        let selectedDirectory = selectedURL.standardizedFileURL
        FolderAuthorizationStore.shared.authorizeFolder(selectedDirectory)

        let candidates = [
            selectedDirectory,
            selectedDirectory.appending(path: expectedDirectoryName),
        ]
        guard let modelURL = candidates.first(where: { isValidModelDirectory($0) }) else {
            showInvalidModelAlert(
                displayName: displayName,
                expectedDirectoryName: expectedDirectoryName,
                selectedURL: selectedDirectory
            )
            blockedStartupMessage = invalidModelBlockedMessage(
                displayName: displayName,
                expectedDirectoryName: expectedDirectoryName
            )
            return nil
        }
        return modelURL.standardizedFileURL
    }

    private func showInvalidModelAlert(
        displayName: String,
        expectedDirectoryName: String,
        selectedURL: URL
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = invalidModelAlertTitle()
        alert.informativeText = invalidModelAlertMessage(
            displayName: displayName,
            expectedDirectoryName: expectedDirectoryName,
            selectedURL: selectedURL
        )
        alert.addButton(withTitle: okButtonTitle())
        alert.runModal()
    }

    private func sourceModelAuthorizationMessage(displayName: String, folderURL: URL) -> String {
        let language = currentAppLanguage()
        switch language {
        case .zh:
            return "MSub 需要读取本地 \(displayName) 模型。请授权包含该模型的文件夹：\(folderURL.path)"
        case .zhHant:
            return "MSub 需要讀取本機 \(displayName) 模型。請授權包含該模型的資料夾：\(folderURL.path)"
        case .ja:
            return "MSub がローカルの \(displayName) モデルを読み込むには、このモデルを含むフォルダの許可が必要です: \(folderURL.path)"
        case .en:
            return "MSub needs access to the local \(displayName) model. Choose the folder that contains this model: \(folderURL.path)"
        }
    }

    private func sourceModelAuthorizationPrompt() -> String {
        switch currentAppLanguage() {
        case .zh: return "授权模型文件夹"
        case .zhHant: return "授權模型資料夾"
        case .ja: return "モデルフォルダを許可"
        case .en: return "Authorize Model Folder"
        }
    }

    private func missingModelAlertTitle() -> String {
        switch currentAppLanguage() {
        case .zh: return "未找到本地模型权重"
        case .zhHant: return "找不到本機模型權重"
        case .ja: return "ローカルモデル重みが見つかりません"
        case .en: return "Local Model Weights Not Found"
        }
    }

    private func missingModelAlertMessage(
        displayName: String,
        expectedDirectoryName: String,
        remoteModelID: String
    ) -> String {
        switch currentAppLanguage() {
        case .zh:
            return "MSub 没有找到 \(displayName) 的本地权重。请选择包含 \(expectedDirectoryName) 的模型文件夹，或允许从 Hugging Face 下载 \(remoteModelID)。"
        case .zhHant:
            return "MSub 沒有找到 \(displayName) 的本機權重。請選擇包含 \(expectedDirectoryName) 的模型資料夾，或允許從 Hugging Face 下載 \(remoteModelID)。"
        case .ja:
            return "MSub は \(displayName) のローカル重みを見つけられませんでした。\(expectedDirectoryName) を含むモデルフォルダを選ぶか、Hugging Face から \(remoteModelID) をダウンロードすることを許可してください。"
        case .en:
            return "MSub could not find the local weights for \(displayName). Choose the model folder that contains \(expectedDirectoryName), or allow MSub to download \(remoteModelID) from Hugging Face."
        }
    }

    private func missingModelChooseButtonTitle() -> String {
        switch currentAppLanguage() {
        case .zh: return "选择本地权重..."
        case .zhHant: return "選擇本機權重..."
        case .ja: return "ローカル重みを選択..."
        case .en: return "Choose Local Weights..."
        }
    }

    private func missingModelDownloadButtonTitle() -> String {
        switch currentAppLanguage() {
        case .zh: return "下载"
        case .zhHant: return "下載"
        case .ja: return "ダウンロード"
        case .en: return "Download"
        }
    }

    private func cancelButtonTitle() -> String {
        switch currentAppLanguage() {
        case .zh: return "取消"
        case .zhHant: return "取消"
        case .ja: return "キャンセル"
        case .en: return "Cancel"
        }
    }

    private func localModelPanelMessage(
        displayName: String,
        expectedDirectoryName: String
    ) -> String {
        switch currentAppLanguage() {
        case .zh:
            return "请选择 \(displayName) 模型文件夹，或选择包含 \(expectedDirectoryName) 的上级文件夹。"
        case .zhHant:
            return "請選擇 \(displayName) 模型資料夾，或選擇包含 \(expectedDirectoryName) 的上層資料夾。"
        case .ja:
            return "\(displayName) のモデルフォルダ、または \(expectedDirectoryName) を含む親フォルダを選択してください。"
        case .en:
            return "Choose the \(displayName) model folder, or the parent folder that contains \(expectedDirectoryName)."
        }
    }

    private func invalidModelAlertTitle() -> String {
        switch currentAppLanguage() {
        case .zh: return "模型文件夹无效"
        case .zhHant: return "模型資料夾無效"
        case .ja: return "モデルフォルダが無効です"
        case .en: return "Invalid Model Folder"
        }
    }

    private func invalidModelAlertMessage(
        displayName: String,
        expectedDirectoryName: String,
        selectedURL: URL
    ) -> String {
        switch currentAppLanguage() {
        case .zh:
            return "所选位置不是有效的 \(displayName) 权重目录：\(selectedURL.path)\n\n请确认它包含 \(expectedDirectoryName)、config.json，以及 .safetensors 或 .npz 权重文件。"
        case .zhHant:
            return "所選位置不是有效的 \(displayName) 權重目錄：\(selectedURL.path)\n\n請確認它包含 \(expectedDirectoryName)、config.json，以及 .safetensors 或 .npz 權重檔。"
        case .ja:
            return "選択した場所は有効な \(displayName) 重みフォルダではありません: \(selectedURL.path)\n\n\(expectedDirectoryName)、config.json、.safetensors または .npz の重みファイルが含まれていることを確認してください。"
        case .en:
            return "The selected location is not a valid \(displayName) weights folder: \(selectedURL.path)\n\nMake sure it contains \(expectedDirectoryName), config.json, and .safetensors or .npz weight files."
        }
    }

    private func missingModelBlockedMessage(displayName: String) -> String {
        switch currentAppLanguage() {
        case .zh:
            return "需要 \(displayName) 权重才能启动识别。请选择本地权重文件夹，或允许下载后再试。"
        case .zhHant:
            return "需要 \(displayName) 權重才能啟動辨識。請選擇本機權重資料夾，或允許下載後再試。"
        case .ja:
            return "\(displayName) の重みが必要です。ローカル重みフォルダを選ぶか、ダウンロードを許可してからもう一度試してください。"
        case .en:
            return "\(displayName) weights are required before transcription can start. Choose local weights or allow download, then try again."
        }
    }

    private func invalidModelBlockedMessage(
        displayName: String,
        expectedDirectoryName: String
    ) -> String {
        switch currentAppLanguage() {
        case .zh:
            return "所选文件夹不是有效的 \(displayName) 权重目录。请重新选择包含 \(expectedDirectoryName) 的模型文件夹。"
        case .zhHant:
            return "所選資料夾不是有效的 \(displayName) 權重目錄。請重新選擇包含 \(expectedDirectoryName) 的模型資料夾。"
        case .ja:
            return "選択したフォルダは有効な \(displayName) 重みフォルダではありません。\(expectedDirectoryName) を含むモデルフォルダを選び直してください。"
        case .en:
            return "The selected folder is not a valid \(displayName) weights directory. Choose the model folder that contains \(expectedDirectoryName)."
        }
    }

    private func okButtonTitle() -> String {
        switch currentAppLanguage() {
        case .zh: return "好"
        case .zhHant: return "好"
        case .ja: return "OK"
        case .en: return "OK"
        }
    }

    private func currentAppLanguage() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "huz.uiLanguage") ?? AppLanguage.zh.rawValue
        return AppLanguage(rawValue: raw) ?? .zh
    }

    private func sourceModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func sourceMiMoModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceMiMoModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func sourceSenseVoiceModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceSenseVoiceModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func isValidMiMoTokenizerPathFromManifest(in workspace: URL, modelURL: URL) -> Bool {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceMiMoTokenizerPath,
              !path.isEmpty else {
            return isValidModelDirectory(modelURL.deletingLastPathComponent().appending(path: "MiMo-Audio-Tokenizer"))
        }
        return isValidModelDirectory(URL(fileURLWithPath: path).standardizedFileURL)
    }

    private func isValidMiMoTokenizerBeside(_ modelURL: URL) -> Bool {
        isValidModelDirectory(modelURL.deletingLastPathComponent().appending(path: "MiMo-Audio-Tokenizer"))
    }

    private func sourceDiarizationModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceDiarizationModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func sourceSpeakerRecognitionModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceSpeakerRecognitionModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func sourceEmotionModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceEmotionModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func sourceFireRedVADModelPathFromManifest(in workspace: URL) -> URL? {
        let manifestURL = workspace.appending(path: "backend-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BackendManifest.self, from: data),
              let path = manifest.sourceFireRedVADModelPath,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func isValidModelDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.appending(path: "config.json").path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: url,
                  includingPropertiesForKeys: nil
              ) else {
            return false
        }
        return files.contains { file in
            let ext = file.pathExtension.lowercased()
            return ext == "safetensors" || ext == "npz"
        }
    }

    private func isValidDiarizationModelDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "config.yaml").path)
    }

    private func isNonEmptyDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: url,
                  includingPropertiesForKeys: nil
              ) else {
            return false
        }
        return !contents.isEmpty
    }

    private func isValidEmotionModelDirectory(_ url: URL) -> Bool {
        isNonEmptyDirectory(url)
            && FileManager.default.fileExists(atPath: url.appending(path: "config.yaml").path)
            && FileManager.default.fileExists(atPath: url.appending(path: "model.pt").path)
    }

    private func isValidSpeakerRecognitionModelDirectory(_ url: URL) -> Bool {
        isNonEmptyDirectory(url)
    }

    private func isValidFireRedVADModelDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "VAD/model.pth.tar").path)
            && FileManager.default.fileExists(atPath: url.appending(path: "VAD/cmvn.ark").path)
    }

    private func appendLog(_ text: String) {
        if recentLog.isEmpty {
            recentLog = text
        } else {
            recentLog += "\n\(text)"
        }
        if recentLog.count > maxRecentLogLength {
            recentLog = String(recentLog.suffix(maxRecentLogLength))
        }
        lastLog = recentLog
    }

    private func stoppedMessage(exitCode: Int32) -> String {
        let log = recentLog
            .split(separator: "\n")
            .suffix(8)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if log.isEmpty {
            return exitCode == 0 ? "Backend stopped" : "Backend stopped (exit \(exitCode))"
        }
        return "Backend stopped (exit \(exitCode))\n\(log)"
    }

    private func availablePort(startingAt preferred: Int) -> Int? {
        for port in preferred..<(preferred + 20) where canBind(port: port) {
            return port
        }
        return nil
    }

    private func canBind(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
