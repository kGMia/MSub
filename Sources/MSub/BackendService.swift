import Darwin
import Foundation

private struct BackendManifest: Decodable {
    let sourceModelPath: String?
}

@MainActor
final class BackendService: ObservableObject {
    @Published var isRunning = false
    @Published var message = "Backend stopped"
    @Published var lastLog = ""
    @Published var baseURL = URL(string: "http://127.0.0.1:7860")!

    private var process: Process?
    private var pipe: Pipe?
    private var recentLog = ""
    private let maxRecentLogLength = 6_000

    func start() {
        guard process == nil else { return }
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
        message = "Starting backend at 127.0.0.1:\(port)"

        var environment = ProcessInfo.processInfo.environment
        let fallbackVenvURL = configureUVEnvironment(&environment, workspace: workspace)
        if let modelPath = bundledOrWorkspaceModel(in: workspace) {
            environment["MSUB_MODEL"] = modelPath.path
            environment["HUZ_MODEL"] = modelPath.path
        }
        environment["MSUB_HOST"] = "127.0.0.1"
        environment["MSUB_PORT"] = "\(port)"
        environment["MSUB_BACKEND_ROOT"] = workspace.path
        environment["MSUB_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
        environment["MSUB_MODEL_IDLE_SECONDS"] = environment["MSUB_MODEL_IDLE_SECONDS"] ?? "120"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["UV_NO_PROGRESS"] = "1"
        environment["UV_LINK_MODE"] = "copy"
        configureJobDirectory(&environment, workspace: workspace)
        configurePythonPath(&environment, workspace: workspace)
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
            process.arguments = ["uv", "run", "msub-web"]
            appendLog("Starting backend with uv run msub-web")
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
                self?.message = self?.stoppedMessage(exitCode: process.terminationStatus) ?? "Backend stopped"
            }
        }

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
            isRunning = true
            message = "Backend running at 127.0.0.1:\(port)"
        } catch {
            message = error.localizedDescription
        }
    }

    func ensureRunning(timeout: TimeInterval = 25.0) async -> Bool {
        let expectedBackendRootPath = expectedBackendRootPath()
        let expectedModelPath = expectedModelPath()
        if await healthCheck(
            url: baseURL,
            expectedBackendRootPath: expectedBackendRootPath,
            expectedModelPath: expectedModelPath
        ) {
            isRunning = true
            message = "Backend running at \(baseURL.host() ?? "127.0.0.1"):\(baseURL.port ?? 7860)"
            return true
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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await healthCheck(
                url: baseURL,
                expectedBackendRootPath: expectedBackendRootPath,
                expectedModelPath: expectedModelPath
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

    func stop() {
        requestBackendShutdown()
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(2.0)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        process = nil
        isRunning = false
        message = "Backend stopped"
    }

    private func requestBackendShutdown() {
        var request = URLRequest(url: baseURL.appending(path: "/api/shutdown"))
        request.httpMethod = "POST"
        request.timeoutInterval = 0.5
        URLSession.shared.dataTask(with: request).resume()
    }

    private func healthCheck(
        url baseURL: URL,
        expectedBackendRootPath: String?,
        expectedModelPath: String?
    ) async -> Bool {
        do {
            let url = baseURL.appending(path: "/api/health")
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200..<300).contains(http.statusCode) else { return false }
            if let expectedBackendRootPath {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let backendRoot = object["backendRoot"] as? String,
                      pathsReferToSameFile(backendRoot, expectedBackendRootPath) else {
                    return false
                }
            }
            guard let expectedModelPath else { return true }
            return await configMatchesExpectedModel(baseURL: baseURL, expectedModelPath: expectedModelPath)
        } catch {
            return false
        }
    }

    private func configMatchesExpectedModel(baseURL: URL, expectedModelPath: String) async -> Bool {
        do {
            let url = baseURL.appending(path: "/api/config")
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let defaultModel = object["defaultModel"] as? String else {
                return false
            }
            return pathsReferToSameFile(defaultModel, expectedModelPath)
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
              let modelURL = bundledOrWorkspaceModel(in: workspace) else {
            return nil
        }
        return modelURL.standardizedFileURL.path
    }

    private func expectedBackendRootPath() -> String? {
        findWorkspaceRoot()?.standardizedFileURL.path
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

        if isBundledBackend(workspace), let runtimePython = bundledRuntimePython(in: workspace) {
            appendCandidate(runtimePython, label: "bundled Python runtime")
        }
        if isBundledBackend(workspace) {
            appendCandidate(workspace.appending(path: ".venv/bin/python"), label: "bundled backend venv")
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

    private func bundledOrWorkspaceModel(in workspace: URL) -> URL? {
        for key in ["MSUB_MODEL", "HUZ_MODEL"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                let modelURL = URL(fileURLWithPath: value).standardizedFileURL
                if isValidModelDirectory(modelURL) {
                    return modelURL
                }
            }
        }

        let modelPath = workspace.appending(path: "models/FireRedASR2-AED-mlx")
        if isValidModelDirectory(modelPath) {
            return modelPath
        }

        if isBundledBackend(workspace),
           let sourceModelPath = sourceModelPathFromManifest(in: workspace),
           isValidModelDirectory(sourceModelPath) {
            return sourceModelPath
        }

        return nil
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

    private func isValidModelDirectory(_ url: URL) -> Bool {
        let requiredFiles = [
            "model.safetensors",
            "config.json",
            "train_bpe1000.model",
        ]
        return requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: url.appending(path: $0).path)
        }
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
