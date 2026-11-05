import Foundation

struct TranscriptionConfiguration: Sendable {
    let useAPI: Bool
    let apiKey: String?
    let apiModel: String
    let localModel: String
    let language: String?

    init(settings: AppSettings = .shared) {
        useAPI = settings.useAPI
        apiKey = settings.apiKey
        apiModel = settings.apiModel
        localModel = settings.localModel
        language = settings.language
    }
}

enum TranscriberError: Error, LocalizedError {
    /// The chosen on-device model hasn't been downloaded (or is still downloading).
    case modelNotDownloaded(String)
    case outputMissing
    case timedOut

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name):
            return "The \(name) model isn't downloaded yet. Download it in Settings › Transcription."
        case .outputMissing:
            return "Transcription returned no text."
        case .timedOut:
            return "Transcription timed out. Try a shorter recording or a smaller local model."
        }
    }
}

final class Transcriber {
    func transcribe(
        audioURL: URL,
        configuration: TranscriptionConfiguration,
        timeout: TimeInterval = 600
    ) async throws -> String {
        if configuration.useAPI {
            return try await Self.transcribeAPI(audioURL: audioURL, configuration: configuration)
        }
        return try await Self.withTimeout(timeout) {
            try await LocalWhisperEngine.shared.transcribe(
                audioURL: audioURL,
                modelID: configuration.localModel,
                language: configuration.language
            )
        }
    }

    /// Runs `body`, cancelling it and throwing `.timedOut` if it outlives `seconds`.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TranscriberError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private static func transcribeAPI(
        audioURL: URL,
        configuration: TranscriptionConfiguration
    ) async throws -> String {
        guard let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw NSError(
                domain: "Whisper",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing OpenAI API key in Settings."]
            )
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MultipartFormDataBuilder.build(
            boundary: boundary,
            audioURL: audioURL,
            model: configuration.apiModel,
            language: configuration.language
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            let message = apiErrorMessage(from: data) ?? "The transcription service returned an error."
            throw NSError(domain: "Whisper", code: -2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let transcript = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else {
            throw TranscriberError.outputMissing
        }
        return transcript
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

enum MultipartFormDataBuilder {
    static func build(
        boundary: String,
        audioURL: URL,
        model: String,
        language: String?
    ) throws -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("text\r\n")

        if let language, !language.isEmpty, language.lowercased() != "auto" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        data.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")
        return data
    }
}
