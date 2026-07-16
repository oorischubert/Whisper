import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var activity: AppActivity = .idle
    private var comboMonitor: GlobalShortcutMonitor?
    private var dictationHotKey: HotKeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var preferencesWindowController: NSWindowController?
    private var loadingAnimator: LoadingAnimator?
    private var transcriptionTask: Task<Void, Never>?
    private lazy var hud = HUDWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupGlobalShortcut()
        setupDictationKey()
        UNUserNotificationCenter.current().delegate = self

        if !AppSettings.shared.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in self?.showPreferences(initialTab: .setup) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriptionTask?.cancel()
        if activity.isRecording, let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        // Synchronous by necessity: a Task would not finish before we exit, and leaving
        // the remap behind would make the mic key silently dead until the next launch.
        if AppSettings.shared.dictationKeyEnabled {
            DictationKeyRemapper.removeSync()
        }
    }

    private func setupGlobalShortcut() {
        comboMonitor = GlobalShortcutMonitor(
            keyCode: AppSettings.shared.comboKeyCode,
            modifiers: AppSettings.shared.comboModifiers
        ) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }

        AppSettings.shared.$comboKeyCode
            .merge(with: AppSettings.shared.$comboModifiers.map { _ in AppSettings.shared.comboKeyCode })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.comboMonitor?.update(
                    keyCode: AppSettings.shared.comboKeyCode,
                    modifiers: AppSettings.shared.comboModifiers
                )
                self?.refreshMenu()
            }
            .store(in: &cancellables)
    }

    private func setupDictationKey() {
        Task { @MainActor in await syncDictationKey(enabled: AppSettings.shared.dictationKeyEnabled) }

        // Use the value the publisher delivers: @Published fires in willSet, so reading
        // the property back inside this sink would see the *old* value.
        AppSettings.shared.$dictationKeyEnabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                Task { @MainActor in await self?.syncDictationKey(enabled: enabled) }
            }
            .store(in: &cancellables)

        // A keyboard re-enumerating on wake can drop the mapping.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard AppSettings.shared.dictationKeyEnabled else { return }
                await DictationKeyRemapper.shared.apply()
            }
        }
    }

    private func syncDictationKey(enabled: Bool) async {
        guard enabled else {
            dictationHotKey = nil // deinit unregisters
            await DictationKeyRemapper.shared.remove()
            return
        }

        await DictationKeyRemapper.shared.apply()
        guard DictationKeyRemapper.shared.status == .active else {
            dictationHotKey = nil
            return
        }

        do {
            dictationHotKey = try HotKeyManager(keyCode: UInt32(kVK_F13)) { [weak self] in
                Task { @MainActor in self?.handleDictationKey() }
            }
        } catch {
            // Without the key bound, the remap would only suppress Dictation and give
            // nothing back — a dead mic key. Undo it rather than leave it that way.
            dictationHotKey = nil
            await DictationKeyRemapper.shared.remove()
            DictationKeyRemapper.shared.noteFailure(error.localizedDescription)
        }
    }

    private func handleDictationKey() {
        // While the Settings "Test" button is armed, report the press instead of acting
        // on it — otherwise testing the key would start a recording.
        if DictationKeyRemapper.shared.isTesting {
            DictationKeyRemapper.shared.noteTestPress()
            return
        }
        toggleRecording()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let primary: NSMenuItem
        switch activity {
        case .idle:
            primary = NSMenuItem(title: "Start Recording", action: #selector(handleStartStop), keyEquivalent: "")
            primary.image = makeMenuImage(systemName: "mic.fill")
        case .recording:
            primary = NSMenuItem(title: "Stop and Transcribe", action: #selector(handleStartStop), keyEquivalent: "")
            primary.image = makeMenuImage(systemName: "stop.fill")
        case .transcribing:
            primary = NSMenuItem(title: "Cancel Transcription", action: #selector(cancelTranscription), keyEquivalent: "")
            primary.image = makeMenuImage(systemName: "xmark")
        }
        primary.target = self
        menu.addItem(primary)

        if activity.isRecording {
            let cancel = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
            cancel.target = self
            cancel.image = makeMenuImage(systemName: "xmark")
            menu.addItem(cancel)
        }

        let shortcut = NSMenuItem(
            title: "Shortcut: \(hotkeyDescription())",
            action: nil,
            keyEquivalent: ""
        )
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        settings.image = makeMenuImage(systemName: "gearshape")
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Whisper", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = makeMenuImage(systemName: "power")
        menu.addItem(quit)
        return menu
    }

    private func updateStatusItem() {
        let symbol: String
        let accessibilityDescription: String
        switch activity {
        case .idle:
            symbol = "waveform"
            accessibilityDescription = "Whisper — ready"
        case .recording:
            symbol = "waveform.badge.mic"
            accessibilityDescription = "Whisper — recording"
        case .transcribing:
            symbol = "waveform"
            accessibilityDescription = "Whisper — transcribing"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityDescription
        )
        statusItem.button?.toolTip = accessibilityDescription
        statusItem.menu = buildMenu()
    }

    private func setActivity(_ newActivity: AppActivity) {
        activity = newActivity
        if newActivity.isTranscribing {
            startLoadingAnimation()
        } else {
            stopLoadingAnimation()
        }
        updateStatusItem()
    }

    private func refreshMenu() {
        statusItem.menu = buildMenu()
    }

    @objc private func handleStartStop() {
        toggleRecording()
    }

    private func toggleRecording() {
        switch activity {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
            setActivity(.recording(startedAt: Date()))
            SoundPlayer.playStart()
        } catch {
            showAlert("Microphone unavailable", message: error.localizedDescription)
        }
    }

    private func stopAndTranscribe() {
        guard activity.isRecording else { return }
        // Chime only after the recorder is closed, so it cannot land in the audio.
        let audioURL = recorder.stop()
        SoundPlayer.playStop()
        setActivity(.transcribing)

        guard let audioURL else {
            setActivity(.idle)
            showAlert("Recording failed", message: "No audio file was created.")
            return
        }

        let configuration = TranscriptionConfiguration()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: audioURL)
                self.transcriptionTask = nil
                self.setActivity(.idle)
            }

            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
                // Started and stopped without speaking: nothing to transcribe, and
                // nothing worth interrupting the user over. Drop it silently.
                guard byteCount >= 3_600 else { return }

                let text = try await self.transcriber.transcribe(
                    audioURL: audioURL,
                    configuration: configuration
                )
                AppSettings.shared.lastTranscript = text

                var pasted = PasteboardManager.paste(
                    text: text,
                    pressEnter: AppSettings.shared.pressEnterAfterPaste,
                    preserveClipboard: AppSettings.shared.preserveClipboard
                )
                if AppSettings.shared.debugPasteToXcode,
                   let xcode = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.dt.Xcode"
                   ).first {
                    xcode.activate()
                    try? await Task.sleep(for: .milliseconds(300))
                    pasted = PasteboardManager.paste(
                        text: text,
                        pressEnter: false,
                        preserveClipboard: false
                    ) || pasted
                }

                showTranscriptHUD(text)
                if pasted {
                    notify("Pasted transcript", subtitle: nil)
                } else {
                    notify("Copied transcript", subtitle: "Press Command–V to paste")
                }
            } catch is CancellationError {
                notify("Transcription cancelled", subtitle: nil)
            } catch {
                showAlert("Transcription failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func cancelRecording() {
        guard activity.isRecording else { return }
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        SoundPlayer.playStop()
        setActivity(.idle)
    }

    @objc private func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    @objc private func openPreferences() {
        showPreferences(initialTab: .transcription)
    }

    private func showPreferences(initialTab: PreferencesView.PrefsTab) {
        if let windowController = preferencesWindowController {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: PreferencesView(initialTab: initialTab))
        let window = NSWindow(contentViewController: controller)
        window.title = "Whisper Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        let windowController = NSWindowController(window: window)
        preferencesWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(self)
    }

    private func makeMenuImage(systemName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = true
        return configured
    }

    private func hotkeyDescription() -> String {
        let modifiers = AppSettings.shared.comboModifiers
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        value += PreferencesView.keyDisplayName(for: AppSettings.shared.comboKeyCode)
        return value
    }

    private func notify(_ title: String, subtitle: String?) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        #if DEBUG
        NSLog("[Whisper] \(title)")
        #endif
    }

    private func showAlert(_ title: String, message: String?) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.alertStyle = .warning
        alert.runModal()
        #if DEBUG
        NSLog("[Whisper] \(title)")
        #endif
    }

    private func startLoadingAnimation() {
        guard let button = statusItem.button else { return }
        loadingAnimator?.stop()
        let animator = LoadingAnimator { [weak button] glyph in button?.title = glyph }
        loadingAnimator = animator
        animator.start()
    }

    private func stopLoadingAnimation() {
        loadingAnimator?.stop()
        statusItem?.button?.title = ""
    }

    private func showTranscriptHUD(_ text: String) {
        guard AppSettings.shared.debugShowPopup else { return }
        hud.show(text: text)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
