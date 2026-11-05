import Foundation
import Combine
import WhisperKit

// MARK: - Catalog

/// A Whisper model the app can download and run on this Mac.
struct LocalModel: Identifiable, Hashable, Sendable {
    /// Folder name in the `argmaxinc/whisperkit-coreml` repository.
    let id: String
    let name: String
    let summary: String
    let downloadBytes: Int64
    var isRecommended = false

    var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }

    static let catalog: [LocalModel] = [
        LocalModel(
            id: "openai_whisper-tiny",
            name: "Tiny",
            summary: "Fastest, but makes the most mistakes.",
            downloadBytes: 77_000_000
        ),
        LocalModel(
            id: "openai_whisper-base",
            name: "Base",
            summary: "Quick and light. Good for clear speech.",
            downloadBytes: 147_000_000
        ),
        LocalModel(
            id: "openai_whisper-small",
            name: "Small",
            summary: "More accurate, a little slower.",
            downloadBytes: 486_000_000
        ),
        LocalModel(
            id: "openai_whisper-large-v3-v20240930_626MB",
            name: "Large v3 Turbo",
            summary: "Near-best accuracy at a fraction of the wait.",
            downloadBytes: 627_000_000,
            isRecommended: true
        ),
        LocalModel(
            id: "openai_whisper-large-v3_947MB",
            name: "Large v3",
            summary: "Highest accuracy, slowest to transcribe.",
            downloadBytes: 948_000_000
        ),
    ]

    static let defaultID = "openai_whisper-base"

    static func model(withID id: String) -> LocalModel? {
        catalog.first { $0.id == id }
    }

    /// Maps what older builds stored — the Python engine's short names like
    /// "base" or "large" — onto a catalog ID, so an upgrade keeps the user's pick.
    static func migratedID(from stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return defaultID }
        if model(withID: stored) != nil { return stored }
        switch stored.lowercased() {
        case "tiny", "tiny.en": return "openai_whisper-tiny"
        case "base", "base.en": return "openai_whisper-base"
        case "small", "small.en": return "openai_whisper-small"
        case "medium", "medium.en", "turbo": return "openai_whisper-large-v3-v20240930_626MB"
        case "large", "large-v2", "large-v3": return "openai_whisper-large-v3_947MB"
        default: return defaultID
        }
    }
}

// MARK: - Storage

enum LocalModelStorage {
    private static let repoPath = "models/argmaxinc/whisperkit-coreml"
    private static let readyMarker = ".whisper-ready"

    /// Everything lives under Application Support, so deleting a model frees its space.
    static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Whisper/Models", isDirectory: true)
    }

    static func folder(for id: String) -> URL {
        baseDirectory.appendingPathComponent(repoPath).appendingPathComponent(id, isDirectory: true)
    }

    /// The download library keeps per-file bookkeeping beside the repo; it goes when the model goes.
    private static func metadataFolder(for id: String) -> URL {
        baseDirectory.appendingPathComponent(repoPath)
            .appendingPathComponent(".cache/huggingface/download")
            .appendingPathComponent(id, isDirectory: true)
    }

    /// A model only counts as installed once it downloaded *and* loaded once, so an
    /// interrupted download never shows up as ready.
    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: id).appendingPathComponent(readyMarker).path)
    }

    static func markInstalled(_ id: String) throws {
        let marker = folder(for: id).appendingPathComponent(readyMarker)
        try Data().write(to: marker)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        try? FileManager.default.removeItem(at: metadataFolder(for: id))
    }
}

// MARK: - Manager

/// Owns downloading, preparing and deleting local models, and publishes their state for the UI.
@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()

    enum State: Equatable {
        case notDownloaded
        /// 0…1
        case downloading(Double)
        /// Downloaded; loading it once so the first dictation is quick.
        case preparing
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .preparing: return true
            default: return false
            }
        }
    }

    @Published private(set) var states: [String: State] = [:]
    /// The token tells a finishing download whether it's still the current one.
    private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {
        for model in LocalModel.catalog {
            let installed = LocalModelStorage.isInstalled(model.id)
            states[model.id] = installed ? .ready : .notDownloaded
            // A download cut short by quitting leaves partial files with no way to delete them.
            if !installed { LocalModelStorage.remove(model.id) }
        }

        // Keep the chosen model warm in memory so dictation starts instantly, and
        // free it when the user switches models or moves to the API.
        let settings = AppSettings.shared
        settings.$useAPI.combineLatest(settings.$localModel)
            .removeDuplicates { $0 == $1 }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { useAPI, modelID in
                Task { await LocalWhisperEngine.shared.keepWarm(useAPI ? nil : modelID) }
            }
            .store(in: &cancellables)
    }

    func state(for model: LocalModel) -> State {
        states[model.id] ?? .notDownloaded
    }

    func download(_ model: LocalModel) {
        guard tasks[model.id] == nil else { return }
        let id = model.id
        let token = UUID()
        states[id] = .downloading(0)

        let task = Task { [weak self] in
            do {
                _ = try await WhisperKit.download(
                    variant: id,
                    downloadBase: LocalModelStorage.baseDirectory
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in self?.updateProgress(id, fraction) }
                }
                try Task.checkCancellation()
                self?.states[id] = .preparing
                try await LocalWhisperEngine.shared.prepare(id)
                try Task.checkCancellation()
                try LocalModelStorage.markInstalled(id)
                self?.states[id] = .ready
                // Hold it in memory only if it's the one the user will dictate with.
                let settings = AppSettings.shared
                await LocalWhisperEngine.shared.keepWarm(settings.useAPI ? nil : settings.localModel)
            } catch {
                // Superseded (deleted and re-downloaded meanwhile): leave the new attempt alone.
                guard self?.tasks[id]?.token == token else { return }
                LocalModelStorage.remove(id)
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self?.states[id] = .notDownloaded
                } else {
                    self?.states[id] = .failed(Self.describe(error))
                }
            }
            if self?.tasks[id]?.token == token { self?.tasks[id] = nil }
        }
        tasks[id] = (token, task)
    }

    func cancelDownload(_ model: LocalModel) {
        tasks[model.id]?.task.cancel()
    }

    func delete(_ model: LocalModel) {
        tasks[model.id]?.task.cancel()
        tasks[model.id] = nil
        states[model.id] = .notDownloaded
        Task {
            await LocalWhisperEngine.shared.unload(model.id)
            LocalModelStorage.remove(model.id)
            // With the last model gone, clear shared leftovers (tokenizers) too.
            let othersInUse = states.contains { $0.key != model.id && ($0.value == .ready || $0.value.isBusy) }
            if !othersInUse {
                try? FileManager.default.removeItem(at: LocalModelStorage.baseDirectory)
            }
        }
    }

    private func updateProgress(_ id: String, _ fraction: Double) {
        // A late progress report must not drag a finished download back to "downloading".
        guard case .downloading(let current) = states[id] else { return }
        let clamped = min(max(fraction, 0), 1)
        if clamped - current >= 0.005 || clamped == 1 {
            states[id] = .downloading(clamped)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. Connect and try again."
            case .timedOut:
                return "The download timed out. Try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Engine

/// Runs Whisper on-device through WhisperKit (Core ML, on the Neural Engine).
/// Holds at most one model in memory at a time, and frees it after a stretch of no use.
actor LocalWhisperEngine {
    static let shared = LocalWhisperEngine()

    /// How long a loaded model may sit unused before it's freed. Reloading takes a
    /// second or two, which the next dictation pays.
    private(set) var idleTimeout: Duration = .seconds(15 * 60)

    /// WhisperKit isn't Sendable; the actor is the only thing that ever touches it.
    private final class Loaded: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var loaded: (id: String, pipeline: Loaded)?
    private var loading: (id: String, task: Task<Loaded, Error>)?
    private var idleTimer: Task<Void, Never>?
    private var activeTranscriptions = 0
    /// A model switch requested mid-dictation, applied once the dictation finishes.
    private var hasDeferredWarm = false
    private var deferredWarmID: String?

    var loadedModelID: String? { loaded?.id }

    func setIdleTimeout(_ timeout: Duration) {
        idleTimeout = timeout
        restartIdleTimer()
    }

    /// Loads a freshly downloaded model once, which also fetches its tokenizer and
    /// lets Core ML compile it for this Mac. Uses its own instance so switching
    /// models meanwhile can't interrupt it.
    func prepare(_ id: String) async throws {
        let kit = try await Self.makePipeline(id)
        await kit.unloadModels()
    }

    /// Loads `id` in the background (or unloads everything for `nil`) so the next
    /// dictation doesn't pay the load time.
    func keepWarm(_ id: String?) async {
        // Switching now would pull the model out from under a running dictation.
        guard activeTranscriptions == 0 else {
            hasDeferredWarm = true
            deferredWarmID = id
            return
        }
        guard let id, LocalModelStorage.isInstalled(id) else {
            await unloadAll()
            return
        }
        _ = try? await pipeline(for: id)
        restartIdleTimer()
    }

    func unload(_ id: String) async {
        if loading?.id == id {
            loading?.task.cancel()
            loading = nil
        }
        if loaded?.id == id {
            await loaded?.pipeline.kit.unloadModels()
            loaded = nil
        }
    }

    private func unloadAll() async {
        idleTimer?.cancel()
        idleTimer = nil
        loading?.task.cancel()
        loading = nil
        await loaded?.pipeline.kit.unloadModels()
        loaded = nil
    }

    func transcribe(audioURL: URL, modelID: String, language: String?) async throws -> String {
        guard LocalModelStorage.isInstalled(modelID) else {
            let name = LocalModel.model(withID: modelID)?.name ?? modelID
            throw TranscriberError.modelNotDownloaded(name)
        }
        // No unloading mid-dictation; the idle clock restarts once this one is done.
        activeTranscriptions += 1
        idleTimer?.cancel()
        do {
            let text = try await runTranscription(audioURL: audioURL, modelID: modelID, language: language)
            await finishTranscription()
            return text
        } catch {
            await finishTranscription()
            throw error
        }
    }

    private func finishTranscription() async {
        activeTranscriptions -= 1
        guard activeTranscriptions == 0 else { return }
        if hasDeferredWarm {
            hasDeferredWarm = false
            await keepWarm(deferredWarmID)
        } else {
            restartIdleTimer()
        }
    }

    private func runTranscription(audioURL: URL, modelID: String, language: String?) async throws -> String {
        let kit = try await pipeline(for: modelID).kit

        let autoDetect = language == nil || language?.isEmpty == true || language?.lowercased() == "auto"
        let options = DecodingOptions(
            task: .transcribe,
            language: autoDetect ? nil : language,
            detectLanguage: autoDetect,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        try Task.checkCancellation()

        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { throw TranscriberError.outputMissing }
        return text
    }

    /// Starts (or restarts) the countdown to freeing the loaded model.
    private func restartIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
        guard loaded != nil, activeTranscriptions == 0 else { return }
        let timeout = idleTimeout
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard activeTranscriptions == 0, loading == nil else { return }
        idleTimer = nil
        await loaded?.pipeline.kit.unloadModels()
        loaded = nil
    }

    private func pipeline(for id: String) async throws -> Loaded {
        if let loaded, loaded.id == id { return loaded.pipeline }
        if let loading, loading.id == id { return try await loading.task.value }

        // Switching models: free the old one before loading the next.
        await unloadAll()

        let task = Task<Loaded, Error> { Loaded(try await Self.makePipeline(id)) }
        loading = (id, task)

        do {
            let pipeline = try await task.value
            // Something else may have taken over while this was loading.
            guard loading?.id == id else {
                await pipeline.kit.unloadModels()
                throw CancellationError()
            }
            loading = nil
            loaded = (id, pipeline)
            return pipeline
        } catch {
            if loading?.id == id { loading = nil }
            throw error
        }
    }

    private static func makePipeline(_ id: String) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: LocalModelStorage.folder(for: id).path,
            tokenizerFolder: LocalModelStorage.baseDirectory,
            verbose: false,
            logLevel: .none,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }
}
