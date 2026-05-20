import Foundation

@MainActor
final class APIClient: ObservableObject {
    @Published var baseURL = URL(string: "http://127.0.0.1:7860")!

    func fetchConfig() async throws -> AppConfig {
        let url = baseURL.appending(path: "/api/config")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func preview(fileURL: URL, settings: TranscriptionSettings) async throws -> SegmentPreview {
        let request = try multipartRequest(path: "/api/preview", fileURL: fileURL, settings: settings, includeOutput: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SegmentPreview.self, from: data)
    }

    func createJob(fileURL: URL, settings: TranscriptionSettings) async throws -> JobCreated {
        let request = try multipartRequest(path: "/api/jobs", fileURL: fileURL, settings: settings, includeOutput: true)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(JobCreated.self, from: data)
    }

    func jobStatus(id: String) async throws -> JobStatus {
        let url = baseURL.appending(path: "/api/jobs/\(id)")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    func downloadURL(jobID: String) -> URL {
        baseURL.appending(path: "/api/jobs/\(jobID)/download")
    }

    func fetchOutput(jobID: String) async throws -> DownloadedOutput {
        let url = downloadURL(jobID: jobID)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        let filename = filename(from: response) ?? "subtitle.srt"
        return DownloadedOutput(data: data, filename: filename)
    }

    private func multipartRequest(
        path: String,
        fileURL: URL,
        settings: TranscriptionSettings,
        includeOutput: Bool
    ) throws -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let fields = settings.formFields(includeOutput: includeOutput)
        for (name, value) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "Request failed"
            throw NSError(domain: "MSub.API", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
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
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
