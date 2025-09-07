import Foundation
import ServiceManagement
import AppKit

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var localModel: String {
        didSet { defaults.set(localModel, forKey: Keys.localModel) }
    }

    // Python executable used to run Whisper locally (python -m whisper ...)
    @Published var pythonExecutablePath: String {
        didSet {
            defaults.set(pythonExecutablePath, forKey: Keys.pythonExecutablePath)
            attemptBookmarkForPythonPath()
        }
    }
    // Security-scoped bookmark to the executable directory (for App Sandbox access)
    @Published var whisperBookmarkData: Data? { // name kept for backward-compat
        didSet { defaults.set(whisperBookmarkData, forKey: Keys.whisperBookmarkData) }
    }

    @Published var pressEnterAfterPaste: Bool {
        didSet { defaults.set(pressEnterAfterPaste, forKey: Keys.pressEnterAfterPaste) }
    }

    @Published var preserveClipboard: Bool {
        didSet { defaults.set(preserveClipboard, forKey: Keys.preserveClipboard) }
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }

    @Published var useAPI: Bool {
        didSet { defaults.set(useAPI, forKey: Keys.useAPI) }
    }

    @Published var apiKey: String? {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    @Published var apiModel: String {
        didSet { defaults.set(apiModel, forKey: Keys.apiModel) }
    }

    @Published var language: String? {
        didSet { defaults.set(language, forKey: Keys.language) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    // Ephemeral debug value (not persisted)
    @Published var lastTranscript: String = ""

    // Debug: bring Xcode to front before pasting
    @Published var debugPasteToXcode: Bool {
        didSet { defaults.set(debugPasteToXcode, forKey: Keys.debugPasteToXcode) }
    }
    @Published var debugShowPopup: Bool {
        didSet { defaults.set(debugShowPopup, forKey: Keys.debugShowPopup) }
    }

    // Global shortcut (combo) — default: Control+A
    @Published var comboKeyCode: UInt16 {
        didSet { defaults.set(Int(comboKeyCode), forKey: Keys.comboKeyCode) }
    }
    @Published var comboModifiers: NSEvent.ModifierFlags {
        didSet { defaults.set(comboModifiers.rawValue, forKey: Keys.comboModifiers) }
    }

    private init() {
        let model = defaults.string(forKey: Keys.localModel) ?? "base"
        self.localModel = model

        let py = defaults.string(forKey: Keys.pythonExecutablePath) ?? AppSettings.defaultPythonPath()
        self.pythonExecutablePath = py
        self.whisperBookmarkData = defaults.data(forKey: Keys.whisperBookmarkData)

        self.pressEnterAfterPaste = defaults.object(forKey: Keys.pressEnterAfterPaste) as? Bool ?? false
        self.preserveClipboard = defaults.object(forKey: Keys.preserveClipboard) as? Bool ?? true
        let hk = UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode))
        self.hotkeyKeyCode = (hk == 0) ? 96 : hk // F5 default
        self.useAPI = defaults.object(forKey: Keys.useAPI) as? Bool ?? false
        self.apiKey = defaults.string(forKey: Keys.apiKey)
        self.apiModel = defaults.string(forKey: Keys.apiModel) ?? "whisper-1"
        self.language = defaults.string(forKey: Keys.language) ?? "auto"
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.debugPasteToXcode = defaults.object(forKey: Keys.debugPasteToXcode) as? Bool ?? false
        let ck = defaults.integer(forKey: Keys.comboKeyCode)
        self.comboKeyCode = ck == 0 ? 0 : UInt16(ck)
        let cmRaw = defaults.object(forKey: Keys.comboModifiers) as? UInt ?? NSEvent.ModifierFlags.control.rawValue
        self.comboModifiers = NSEvent.ModifierFlags(rawValue: cmRaw)
        self.debugShowPopup = defaults.object(forKey: Keys.debugShowPopup) as? Bool ?? false
        applyLaunchAtLogin()
    }

    func resolvePythonExecutable() -> String? {
        // User-defined path takes precedence (expand ~ for robustness)
        if !pythonExecutablePath.isEmpty {
            return (pythonExecutablePath as NSString).expandingTildeInPath
        }
        var candidates: [String] = []
        // Common system/Homebrew locations
        candidates += [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        // Search PATH for 'python3' then 'python'
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let parts = pathEnv.split(separator: ":").map(String.init)
            for dir in parts {
                let expanded = (dir as NSString).expandingTildeInPath
                for name in ["python3", "python"] {
                    let candidate = URL(fileURLWithPath: expanded).appendingPathComponent(name).path
                    candidates.append(candidate)
                }
            }
        }
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return c
            }
        }
        return nil
    }

    func updatePythonPath(with url: URL) {
        pythonExecutablePath = url.path
        let dirURL = url.deletingLastPathComponent()
        do {
            let data = try dirURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            whisperBookmarkData = data
        } catch {
            // Ignore bookmark errors; path may still work if not fully sandboxed
        }
    }

    // Temporary shim to keep old call sites working if any remain
    func updateWhisperPath(with url: URL) { updatePythonPath(with: url) }

    private func attemptBookmarkForPythonPath() {
        let path = pythonExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let dirURL = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue {
            if let data = try? dirURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                whisperBookmarkData = data
            }
        }
    }

    func withWhisperAccess<T>(_ body: () throws -> T) rethrows -> T {
        var scopedURL: URL?
        if let data = whisperBookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() {
                    scopedURL = url
                }
            }
        }
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        return try body()
    }

    private static func defaultPythonPath() -> String {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") { return "/opt/homebrew/bin/python3" }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3") { return "/usr/local/bin/python3" }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") { return "/usr/bin/python3" }
        return ""
    }

    enum Keys {
        static let localModel = "localModel"
        static let pythonExecutablePath = "pythonExecutablePath"
        static let whisperBookmarkData = "whisperBookmarkData"
        static let pressEnterAfterPaste = "pressEnterAfterPaste"
        static let preserveClipboard = "preserveClipboard"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let useAPI = "useAPI"
        static let apiKey = "apiKey"
        static let apiModel = "apiModel"
        static let language = "language"
        static let launchAtLogin = "launchAtLogin"
        static let debugPasteToXcode = "debugPasteToXcode"
        static let comboKeyCode = "comboKeyCode"
        static let comboModifiers = "comboModifiers"
        static let debugShowPopup = "debugShowPopup"
    }

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Ignore errors in dev builds (often requires codesigning)
            }
        }
    }
}
