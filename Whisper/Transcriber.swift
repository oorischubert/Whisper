import Foundation

struct TranscriptionConfiguration: Sendable {
    let useAPI: Bool
    let apiKey: String?
    let apiModel: String
    let localModel: String
    let language: String?
    let pythonExecutablePath: String?
    let pythonBookmarkData: Data?

    init(settings: AppSettings = .shared) {
        useAPI = settings.useAPI
        apiKey = settings.apiKey
        apiModel = settings.apiModel
        localModel = settings.localModel
        language = settings.language
        pythonExecutablePath = settings.resolvePythonExecutable()
        pythonBookmarkData = settings.whisperBookmarkData
    }
}

enum TranscriberError: Error, LocalizedError {
    case pythonNotFound
    case failedMessage(Int32, String)
    case outputMissing
    case timedOut

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not find a Python executable. Set its path in Settings."
        case .failedMessage(let code, let message):
            return "Whisper exited with status \(code).\n\n\(message)"
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
        let worker = Task.detached(priority: .userInitiated) {
            try Self.transcribeLocal(audioURL: audioURL, configuration: configuration, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func transcribeLocal(
        audioURL: URL,
        configuration: TranscriptionConfiguration,
        timeout: TimeInterval
    ) throws -> String {
        guard let configuredPath = configuration.pythonExecutablePath else {
            throw TranscriberError.pythonNotFound
        }

        let originalPath = (configuredPath as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        var pythonPath = originalPath
        if !fileManager.isExecutableFile(atPath: pythonPath) {
            let directory = (originalPath as NSString).deletingLastPathComponent
            let alternatives = ["python3", "python"].map {
                (directory as NSString).appendingPathComponent($0)
            }
            guard let executable = alternatives.first(where: fileManager.isExecutableFile(atPath:)) else {
                throw TranscriberError.failedMessage(
                    -2,
                    "Configured Python is not executable: \(originalPath)"
                )
            }
            pythonPath = executable
        }

        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whisper_out_\(UUID().uuidString)")
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outputDirectory) }

        return try withSecurityScopedAccess(configuration.pythonBookmarkData) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            var arguments = [
                "-m", "whisper", audioURL.path,
                "--model", configuration.localModel,
                "--fp16", "False",
                "--output_format", "txt",
                "--verbose", "False",
                "--output_dir", outputDirectory.path
            ]
            if let language = configuration.language,
               !language.isEmpty,
               language.lowercased() != "auto" {
                arguments += ["--language", language]
            }
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            let pythonBin = (pythonPath as NSString).deletingLastPathComponent
            for directory in [pythonBin, "/opt/homebrew/bin", "/usr/local/bin"] {
                let existing = environment["PATH"] ?? ""
                if !existing.split(separator: ":").contains(Substring(directory)) {
                    environment["PATH"] = existing.isEmpty ? directory : directory + ":" + existing
                }
            }
            process.environment = environment

            // A file avoids the classic pipe-capacity deadlock when a child emits lots of output.
            let diagnosticsURL = outputDirectory.appendingPathComponent("process.log")
            fileManager.createFile(atPath: diagnosticsURL.path, contents: nil)
            let diagnostics = try FileHandle(forWritingTo: diagnosticsURL)
            process.standardOutput = diagnostics
            process.standardError = diagnostics

            #if DEBUG
            NSLog("[Whisper] Starting local transcription with model \(configuration.localModel)")
            #endif

            do {
                try process.run()
            } catch {
                try? diagnostics.close()
                throw error
            }

            let startedAt = Date()
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    process.waitUntilExit()
                    try? diagnostics.close()
                    throw CancellationError()
                }
                if Date().timeIntervalSince(startedAt) > timeout {
                    process.terminate()
                    process.waitUntilExit()
                    try? diagnostics.close()
                    throw TranscriberError.timedOut
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            process.waitUntilExit()
            try? diagnostics.close()

            if process.terminationStatus != 0 {
                let data = (try? Data(contentsOf: diagnosticsURL)) ?? Data()
                var message = String(data: data, encoding: .utf8) ?? "No diagnostic output."
                message = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercased = message.lowercased()
                var hints: [String] = []
                if lowercased.contains("no module named whisper") || lowercased.contains("module named 'whisper'") {
                    hints.append("The selected Python does not have openai-whisper installed.")
                }
                if lowercased.contains("ffmpeg") && (lowercased.contains("not found") || lowercased.contains("no such file")) {
                    hints.append("ffmpeg was not found. Install it or add it to PATH.")
                }
                if !hints.isEmpty {
                    message += "\n\n" + hints.joined(separator: "\n")
                }
                throw TranscriberError.failedMessage(process.terminationStatus, message)
            }

            let baseName = audioURL.deletingPathExtension().lastPathComponent
            let transcriptURL = outputDirectory.appendingPathComponent("\(baseName).txt")
            guard let data = try? Data(contentsOf: transcriptURL),
                  let transcript = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty else {
                throw TranscriberError.outputMissing
            }
            return transcript
        }
    }

    private static func withSecurityScopedAccess<T>(_ bookmarkData: Data?, body: () throws -> T) rethrows -> T {
        var scopedURL: URL?
        if let bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() {
                scopedURL = url
            }
        }
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        return try body()
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
