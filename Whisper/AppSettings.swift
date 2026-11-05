import Foundation
import ServiceManagement
import AppKit

/// Which quick-action buttons ride alongside the menu-bar icon.
enum StatusControlsMode: Int, CaseIterable, Identifiable {
    /// Just the icon, like the original app — the menu handles everything.
    case iconOnly = 0
    /// A cancel (✕) button appears while recording or transcribing.
    case cancelOnly = 1
    /// A start/stop button is always shown; cancel (✕) joins it while active.
    case full = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "Icon Only"
        case .cancelOnly: return "Cancel Button"
        case .full: return "Full Controls"
        }
    }

    var detail: String {
        switch self {
        case .iconOnly:
            return "Just the menu-bar icon. Click it to open the menu with every action."
        case .cancelOnly:
            return "While recording or transcribing, a cancel (✕) button appears next to the icon."
        case .full:
            return "A start/stop button is always shown. While recording, a cancel (✕) button joins it."
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// A `LocalModel.catalog` ID — the on-device model used when not on the API.
    @Published var localModel: String {
        didSet { defaults.set(localModel, forKey: Keys.localModel) }
    }

    @Published var pressEnterAfterPaste: Bool {
        didSet { defaults.set(pressEnterAfterPaste, forKey: Keys.pressEnterAfterPaste) }
    }

    @Published var preserveClipboard: Bool {
        didSet { defaults.set(preserveClipboard, forKey: Keys.preserveClipboard) }
    }

    // Remap the mic key (F5) to toggle Whisper instead of opening macOS Dictation
    @Published var dictationKeyEnabled: Bool {
        didSet { defaults.set(dictationKeyEnabled, forKey: Keys.dictationKeyEnabled) }
    }

    @Published var useAPI: Bool {
        didSet { defaults.set(useAPI, forKey: Keys.useAPI) }
    }

    @Published var apiKey: String? {
        didSet {
            KeychainStore.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.removeObject(forKey: Keys.apiKey)
        }
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

    // Chime when a recording starts and stops, the way macOS Dictation does
    @Published var soundFeedbackEnabled: Bool {
        didSet { defaults.set(soundFeedbackEnabled, forKey: Keys.soundFeedbackEnabled) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
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

    // Which quick-action buttons appear next to the menu-bar icon
    @Published var statusControlsMode: StatusControlsMode {
        didSet { defaults.set(statusControlsMode.rawValue, forKey: Keys.statusControlsMode) }
    }

    private init() {
        // Older builds stored the Python engine's short names ("base", "large"…).
        let model = LocalModel.migratedID(from: defaults.string(forKey: Keys.localModel))
        self.localModel = model
        defaults.set(model, forKey: Keys.localModel)
        // Leftovers from the Python engine, which is gone.
        defaults.removeObject(forKey: Keys.legacyPythonExecutablePath)
        defaults.removeObject(forKey: Keys.legacyWhisperBookmarkData)

        self.pressEnterAfterPaste = defaults.object(forKey: Keys.pressEnterAfterPaste) as? Bool ?? false
        self.preserveClipboard = defaults.object(forKey: Keys.preserveClipboard) as? Bool ?? true
        self.dictationKeyEnabled = defaults.object(forKey: Keys.dictationKeyEnabled) as? Bool ?? false
        self.useAPI = defaults.object(forKey: Keys.useAPI) as? Bool ?? false
        let legacyAPIKey = defaults.string(forKey: Keys.apiKey)
        self.apiKey = KeychainStore.apiKey ?? legacyAPIKey
        self.apiModel = defaults.string(forKey: Keys.apiModel) ?? "gpt-4o-mini-transcribe"
        self.language = defaults.string(forKey: Keys.language) ?? "auto"
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.soundFeedbackEnabled = defaults.object(forKey: Keys.soundFeedbackEnabled) as? Bool ?? true
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.debugPasteToXcode = defaults.object(forKey: Keys.debugPasteToXcode) as? Bool ?? false
        let ck = defaults.integer(forKey: Keys.comboKeyCode)
        self.comboKeyCode = ck == 0 ? 0 : UInt16(ck)
        let cmRaw = defaults.object(forKey: Keys.comboModifiers) as? UInt ?? NSEvent.ModifierFlags.control.rawValue
        self.comboModifiers = NSEvent.ModifierFlags(rawValue: cmRaw)
        self.debugShowPopup = defaults.object(forKey: Keys.debugShowPopup) as? Bool ?? false
        // Remembered across launches; a fresh install starts on Full Controls.
        let controlsRaw = defaults.object(forKey: Keys.statusControlsMode) as? Int ?? StatusControlsMode.full.rawValue
        self.statusControlsMode = StatusControlsMode(rawValue: controlsRaw) ?? .full
        if KeychainStore.apiKey == nil, let legacyAPIKey, !legacyAPIKey.isEmpty {
            KeychainStore.apiKey = legacyAPIKey
        }
        defaults.removeObject(forKey: Keys.apiKey)
        applyLaunchAtLogin()
    }

    enum Keys {
        static let localModel = "localModel"
        static let legacyPythonExecutablePath = "pythonExecutablePath"
        static let legacyWhisperBookmarkData = "whisperBookmarkData"
        static let pressEnterAfterPaste = "pressEnterAfterPaste"
        static let preserveClipboard = "preserveClipboard"
        static let dictationKeyEnabled = "dictationKeyEnabled"
        static let useAPI = "useAPI"
        static let apiKey = "apiKey"
        static let apiModel = "apiModel"
        static let language = "language"
        static let launchAtLogin = "launchAtLogin"
        static let soundFeedbackEnabled = "soundFeedbackEnabled"
        static let debugPasteToXcode = "debugPasteToXcode"
        static let comboKeyCode = "comboKeyCode"
        static let comboModifiers = "comboModifiers"
        static let debugShowPopup = "debugShowPopup"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let statusControlsMode = "statusControlsMode"
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
