import Darwin
import Foundation

@MainActor
final class BackendService: ObservableObject {
    @Published var isRunning = false
    @Published var message = "Backend stopped"
    @Published var lastLog = ""
    @Published var baseURL = URL(string: "http://127.0.0.1:7860")!

    private var process: Process?
    private var pipe: Pipe?

    func start() {
        guard process == nil else { return }
        guard let workspace = findWorkspaceRoot() else {
            message = "Could not find MSub backend"
            return
        }

        let port = availablePort(startingAt: 7860)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!

        let process = Process()
        process.currentDirectoryURL = workspace
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", "msub-web"]
        var environment = ProcessInfo.processInfo.environment
        configureUVEnvironment(&environment, workspace: workspace)
        if let modelPath = bundledOrWorkspaceModel(in: workspace) {
            environment["MSUB_MODEL"] = modelPath.path
            environment["HUZ_MODEL"] = modelPath.path
        }
        environment["MSUB_HOST"] = "127.0.0.1"
        environment["MSUB_PORT"] = "\(port)"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = [
            environment["PATH"],
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        ]
        .compactMap { $0 }
        .joined(separator: ":")
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
                    self?.lastLog = trimmed
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.pipe?.fileHandleForReading.readabilityHandler = nil
                self?.pipe = nil
                self?.process = nil
                self?.isRunning = false
                self?.message = "Backend stopped"
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

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process?.terminate()
        process = nil
        isRunning = false
        message = "Backend stopped"
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

    private func configureUVEnvironment(_ environment: inout [String: String], workspace: URL) {
        if isBundledBackend(workspace) {
            if let cacheURL = appStorageURL(directory: .cachesDirectory, leaf: "uv-cache") {
                environment["UV_CACHE_DIR"] = cacheURL.path
            }
            if let venvURL = appStorageURL(directory: .applicationSupportDirectory, leaf: "backend-venv") {
                environment["UV_PROJECT_ENVIRONMENT"] = venvURL.path
            }
        } else {
            environment["UV_CACHE_DIR"] = ".uv-cache"
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
        let modelPath = workspace.appending(path: "models/FireRedASR2-AED-mlx")
        guard FileManager.default.fileExists(atPath: modelPath.appending(path: "model.safetensors").path) else {
            return nil
        }
        return modelPath
    }

    private func availablePort(startingAt preferred: Int) -> Int {
        for port in preferred..<(preferred + 20) where canBind(port: port) {
            return port
        }
        return preferred
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
