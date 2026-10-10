import Foundation
import Observation

@MainActor
@Observable
final class APIClient {
    var baseURL = URL(string: "http://127.0.0.1:7860")!
    @ObservationIgnored private let session = APIClient.makeSession()

    private var configCacheKey: String { "msub.backendConfig.v1." + Bundle.main.bundleURL.standardizedFileURL.path }

    func cachedConfig() -> AppConfig? {
        guard let data = UserDefaults.standard.data(forKey: configCacheKey) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    func fetchConfig() async throws -> AppConfig {
        let url = baseURL.appending(path: "/api/config")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        UserDefaults.standard.set(data, forKey: configCacheKey)
        return config
    }

    func preview(fileURL: URL, settings: TranscriptionSettings) async throws -> SegmentPreview {
        let data = try await sendMediaRequest(path: "/api/preview", fileURL: fileURL, settings: settings, includeOutput: false)
        return try JSONDecoder().decode(SegmentPreview.self, from: data)
    }

    func createPreviewJob(fileURL: URL, settings: TranscriptionSettings) async throws -> JobCreated {
        let data = try await sendMediaRequest(path: "/api/preview/jobs", fileURL: fileURL, settings: settings, includeOutput: false)
        return try JSONDecoder().decode(JobCreated.self, from: data)
    }

    func downloadPreviewAudio(id: String) async throws -> URL {
        let url = baseURL.appending(path: "/api/preview/\(id)/audio")
        let (temporaryURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try validate(response: response, data: Data())
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "msub-native-\(UUID().uuidString).wav")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func unloadIdleModels() async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/model/unload"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func createJob(
        fileURL: URL,
        settings: TranscriptionSettings,
        previewID: String? = nil,
        nativeSegments: [SubtitleSegment]? = nil,
        fieldOverrides: [(String, String)] = []
    ) async throws -> JobCreated {
        var extraFields = previewID.map { [("preview_id", $0)] } ?? []
        if let nativeSegments {
            let data = try JSONEncoder().encode(nativeSegments)
            extraFields.append(("native_segments", String(decoding: data, as: UTF8.self)))
        }
        let data = try await sendMediaRequest(
            path: "/api/jobs",
            fileURL: fileURL,
            settings: settings,
            includeOutput: true,
            fieldOverrides: fieldOverrides + (nativeSegments == nil ? [] : [("vad_engine", "firered")]),
            extraFields: extraFields
        )
        return try JSONDecoder().decode(JobCreated.self, from: data)
    }

    func createJobFromPreview(previewID: String, settings: TranscriptionSettings) async throws -> JobCreated {
        let data = try await sendMultipart(path: "/api/jobs", fileURL: nil, settings: settings, includeOutput: true, extraFields: [("preview_id", previewID)])
        return try JSONDecoder().decode(JobCreated.self, from: data)
    }

    /// Zero-copy first: the backend runs on this machine, so hand it the local
    /// path and only stream the file when that fails — 409 when the backend
    /// cannot read the path (sandboxed packaged builds), or any other 4xx
    /// (e.g. an older backend without input_path support returns 400/422).
    private func sendMediaRequest(
        path: String,
        fileURL: URL,
        settings: TranscriptionSettings,
        includeOutput: Bool,
        fieldOverrides: [(String, String)] = [],
        extraFields: [(String, String)] = []
    ) async throws -> Data {
        do {
            return try await sendMultipart(
                path: path,
                fileURL: nil,
                settings: settings,
                includeOutput: includeOutput,
                fieldOverrides: fieldOverrides,
                extraFields: extraFields + [("input_path", fileURL.path)]
            )
        } catch let error as NSError where error.domain == "MSub.API" && (400..<500).contains(error.code) {
            return try await sendMultipart(
                path: path,
                fileURL: fileURL,
                settings: settings,
                includeOutput: includeOutput,
                fieldOverrides: fieldOverrides,
                extraFields: extraFields
            )
        }
    }

    private func sendMultipart(
        path: String,
        fileURL: URL?,
        settings: TranscriptionSettings,
        includeOutput: Bool,
        fieldOverrides: [(String, String)] = [],
        extraFields: [(String, String)] = []
    ) async throws -> Data {
        let (request, bodyURL) = try multipartRequest(
            path: path,
            fileURL: fileURL,
            settings: settings,
            includeOutput: includeOutput,
            fieldOverrides: fieldOverrides,
            extraFields: extraFields
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    func updatePreviewSegments(previewID: String, segments: [SubtitleSegment], timeOffset: Double) async throws {
        struct Payload: Encodable {
            let timeOffset: Double
            let segments: [SubtitleSegment]
        }
        var request = URLRequest(url: baseURL.appending(path: "/api/preview/\(previewID)/segments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(timeOffset: timeOffset, segments: segments))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func cancelJob(id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/jobs/\(id)/cancel"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func pauseJob(id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/jobs/\(id)/pause"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func resumeJob(id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/jobs/\(id)/resume"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func jobStatus(id: String) async throws -> JobStatus {
        let url = baseURL.appending(path: "/api/jobs/\(id)")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    /// Streams job status updates over server-sent events, falling back to
    /// interval polling when the event stream is unavailable or interrupted.
    func jobStatusStream(id: String, pollInterval: Duration = .milliseconds(500)) -> AsyncThrowingStream<JobStatus, Error> {
        let url = baseURL.appending(path: "/api/jobs/\(id)/events")
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var sawStreamedTerminal = false
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                        let decoder = JSONDecoder()
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:") else { continue }
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            guard let data = payload.data(using: .utf8),
                                  let status = try? decoder.decode(JobStatus.self, from: data) else { continue }
                            continuation.yield(status)
                            if ["done", "error", "cancelled"].contains(status.status) {
                                sawStreamedTerminal = true
                            }
                        }
                    }
                } catch {
                    // Stream unavailable or interrupted; fall back to polling below.
                }
                if sawStreamedTerminal || Task.isCancelled {
                    continuation.finish()
                    return
                }
                do {
                    while !Task.isCancelled {
                        guard let self else { break }
                        let status = try await self.jobStatus(id: id)
                        continuation.yield(status)
                        if ["done", "error", "cancelled"].contains(status.status) {
                            break
                        }
                        try await Task.sleep(for: pollInterval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func downloadURL(jobID: String) -> URL {
        baseURL.appending(path: "/api/jobs/\(jobID)/download")
    }

    func fetchOutput(jobID: String) async throws -> DownloadedOutput {
        let url = downloadURL(jobID: jobID)
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        let filename = filename(from: response) ?? "subtitle.srt"
        return DownloadedOutput(data: data, filename: filename)
    }

    func fetchModels() async throws -> ManagedModelList {
        let url = baseURL.appending(path: "/api/models")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ManagedModelList.self, from: data)
    }

    func downloadModel(named name: String) async throws {
        try await postModelAction(path: "/api/models/download", name: name)
    }

    func deleteModel(named name: String) async throws {
        try await postModelAction(path: "/api/models/delete", name: name)
    }

    private func postModelAction(path: String, name: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func fetchJobLog(jobID: String) async throws -> DownloadedOutput {
        let url = baseURL.appending(path: "/api/jobs/\(jobID)/log")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        let filename = filename(from: response) ?? "\(jobID).log"
        return DownloadedOutput(data: data, filename: filename)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30 * 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    private func multipartRequest(
        path: String,
        fileURL: URL?,
        settings: TranscriptionSettings,
        includeOutput: Bool,
        fieldOverrides: [(String, String)] = [],
        extraFields: [(String, String)] = []
    ) throws -> (URLRequest, URL) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = path.hasPrefix("/api/preview") ? 30 * 60 : 10 * 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSubUpload-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        let fields = applyingFieldOverrides(
            fieldOverrides,
            to: settings.formFields(includeOutput: includeOutput)
        ) + extraFields
        for (name, value) in fields {
            try output.writeString("--\(boundary)\r\n")
            try output.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try output.writeString("\(value)\r\n")
        }

        if let fileURL {
            let filename = fileURL.lastPathComponent
            try output.writeString("--\(boundary)\r\n")
            try output.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
            try output.writeString("Content-Type: application/octet-stream\r\n\r\n")

            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.writeString("\r\n")
        }

        try output.writeString("--\(boundary)--\r\n")
        let size = try FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber
        request.setValue("\(size?.int64Value ?? 0)", forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = InputStream(url: bodyURL)
        return (request, bodyURL)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = responseErrorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "Request failed"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 1
            throw NSError(domain: "MSub.API", code: code, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    private func responseErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String {
            if let tracePath = object["tracePath"] as? String, !tracePath.isEmpty {
                return "\(detail)\n\(tracePath)"
            }
            return detail
        }
        return nil
    }

    private func filename(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }

        let parts = disposition.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts where part.lowercased().hasPrefix("filename=") {
            let raw = part.dropFirst("filename=".count)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private func applyingFieldOverrides(
        _ overrides: [(String, String)],
        to fields: [(String, String)]
    ) -> [(String, String)] {
        guard !overrides.isEmpty else { return fields }
        var merged = fields
        for override in overrides {
            if let index = merged.firstIndex(where: { $0.0 == override.0 }) {
                merged[index] = override
            } else {
                merged.append(override)
            }
        }
        return merged
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

private extension FileHandle {
    func writeString(_ string: String) throws {
        try write(contentsOf: Data(string.utf8))
    }
}
