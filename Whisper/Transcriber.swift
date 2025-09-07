import Foundation

enum TranscriberError: Error, LocalizedError {
    case pythonNotFound
    case failed(Int32)
    case failedMessage(Int32, String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not find a Python executable. Set its path in Preferences."
        case .failed(let code):
            return "Whisper exited with status \(code)."
        case .failedMessage(let code, let msg):
            return "Whisper exited with status \(code).\n\n\(msg)"
        case .outputMissing:
            return "Transcription output not found."
        }
    }
}

final class Transcriber {
    func transcribe(audioURL: URL) async throws -> String {
        if AppSettings.shared.useAPI {
            return try await transcribeAPI(audioURL: audioURL)
        } else {
            return try transcribeLocal(audioURL: audioURL)
        }
    }

    // Convenience synchronous wrapper for UI code that isn't async-aware
    func transcribeSync(audioURL: URL) throws -> String {
        let sema = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
        Task.detached(priority: .userInitiated) {
            do { let text = try await self.transcribe(audioURL: audioURL); result = .success(text) }
            catch { result = .failure(error) }
            sema.signal()
        }
        sema.wait()
        switch result {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case .none:
            throw NSError(domain: "Whisper", code: -999, userInfo: [NSLocalizedDescriptionKey: "Transcription task did not complete"])
        }
    }

    private func transcribeLocal(audioURL: URL) throws -> String {
        guard let pythonPathResolved = AppSettings.shared.resolvePythonExecutable() else {
            throw TranscriberError.pythonNotFound
        }
        let originalPath = (pythonPathResolved as NSString).expandingTildeInPath
        let fm = FileManager.default
        var pythonPath = originalPath
        if !fm.isExecutableFile(atPath: pythonPath) {
            let dir = (originalPath as NSString).deletingLastPathComponent
            let py3 = (dir as NSString).appendingPathComponent("python3")
            let py  = (dir as NSString).appendingPathComponent("python")
            if fm.isExecutableFile(atPath: py3) {
                pythonPath = py3
            } else if fm.isExecutableFile(atPath: py) {
                pythonPath = py
            } else {
                throw TranscriberError.failedMessage(-2, "Configured Python is not executable: \(originalPath)\nChecked also: \(py3) and \(py)")
            }
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper_out_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let runBlock = {
            () throws -> String in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            var args: [String] = [
                "-m", "whisper", audioURL.path,
                "--model", AppSettings.shared.localModel,
                "--fp16", "False",
                "--output_format", "txt",
                "--verbose", "False",
                "--output_dir", outDir.path
            ]
            if let lang = AppSettings.shared.language, !lang.isEmpty, lang.lowercased() != "auto" {
                args += ["--language", lang]
            }
            proc.arguments = args
            // Ensure env PATH includes the python's bin dir (for ffmpeg) and common brew dirs
            var env = ProcessInfo.processInfo.environment
            let binDir = (pythonPath as NSString).deletingLastPathComponent
            func ensure(_ dir: String) {
                if let old = env["PATH"], !old.split(separator: ":").contains(Substring(dir)) {
                    env["PATH"] = dir + ":" + old
                } else if env["PATH"] == nil {
                    env["PATH"] = dir
                }
            }
            ensure(binDir)
            ensure("/opt/homebrew/bin")
            ensure("/usr/local/bin")
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            // Debug: log command line for diagnostics
            let cmdline = ([pythonPath] + args).joined(separator: " ")
            NSLog("[Whisper] Running: \(cmdline)")

            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                var msg = String(data: data, encoding: .utf8) ?? "(no output)"
                msg = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                // Add friendly hints for common failures
                let lower = msg.lowercased()
                var hints: [String] = []
                if lower.contains("no module named whisper") || lower.contains("module named 'whisper'") {
                    hints.append("Selected Python does not have openai-whisper installed. Activate that env and run: pip install -U openai-whisper")
                }
                if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("no such file")) {
                    hints.append("ffmpeg not found. Install with: brew install ffmpeg (or add it to PATH / your env)")
                }
                if lower.contains("invalid value for '--model'") || lower.contains("model") && lower.contains("not found") {
                    hints.append("Model not available. Choose one of: tiny, base, small, medium, large")
                }
                if !hints.isEmpty {
                    msg += "\n\nHints:\n- " + hints.joined(separator: "\n- ")
                }
                throw TranscriberError.failedMessage(proc.terminationStatus, msg)
            }

            let base = audioURL.deletingPathExtension().lastPathComponent
            let outFile = outDir.appendingPathComponent("\(base).txt")
            guard let data = try? Data(contentsOf: outFile), let text = String(data: data, encoding: .utf8) else {
                throw TranscriberError.outputMissing
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Use security-scoped access if available
        let text: String
        do {
            text = try AppSettings.shared.withWhisperAccess { try runBlock() }
        } catch {
            // Fallback: attempt without scoped access
            text = try runBlock()
        }

        try? FileManager.default.removeItem(at: outDir)
        return text
    }

    // Conda flow removed; unified Python runner approach

    private func transcribeAPI(audioURL: URL) async throws -> String {
        guard let key = AppSettings.shared.apiKey, !key.isEmpty else {
            throw NSError(domain: "Whisper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenAI API key in Preferences."])
        }
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try makeMultipartBody(boundary: boundary, audioURL: audioURL)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let err = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "Whisper", code: -2, userInfo: [NSLocalizedDescriptionKey: err])
        }
        // We asked for text format; server returns text/plain
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeMultipartBody(boundary: String, audioURL: URL) throws -> Data {
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .utf8)!) }
        let line = "\r\n"
        let model = AppSettings.shared.apiModel
        let language = AppSettings.shared.language

        // model
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // response_format=text
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("text\r\n")

        if let language, !language.isEmpty, language.lowercased() != "auto" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        // file
        let filename = audioURL.lastPathComponent
        let fileData = try Data(contentsOf: audioURL)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        data.append(fileData)
        append(line)

        append("--\(boundary)--\r\n")
        return data
    }
}
