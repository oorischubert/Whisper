import AppKit
import SwiftUI
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var isRecording = false
    private var hotKeyManager: HotKeyManager?
    private var comboMonitor: GlobalShortcutMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var prefsWC: NSWindowController?
    private var loadingAnimator: LoadingAnimator?
    private var recordStartAt: TimeInterval = 0
    private var isTranscribing = false
    private lazy var hud = HUDWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        HotKeyManager.requestAccessibilityIfNeeded()
        // Remove legacy F-key hotkey usage
        hotKeyManager = nil

        // New combo hotkey (default: Control+A)
        comboMonitor = GlobalShortcutMonitor(keyCode: AppSettings.shared.comboKeyCode,
                                             modifiers: AppSettings.shared.comboModifiers) { [weak self] in
            self?.toggleRecord()
        }

        AppSettings.shared.$comboKeyCode
            .merge(with: AppSettings.shared.$comboModifiers.map { _ in AppSettings.shared.comboKeyCode })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.comboMonitor?.update(keyCode: AppSettings.shared.comboKeyCode,
                                          modifiers: AppSettings.shared.comboModifiers)
            }
            .store(in: &cancellables)

        // User notifications (modern banners)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper")
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let startStop = NSMenuItem(title: isRecording ? "Stop Recording" : "Start Recording", action: #selector(handleStartStop), keyEquivalent: "")
        startStop.target = self
        menu.addItem(startStop)

        menu.addItem(NSMenuItem.separator())

        let prefs = NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Whisper", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func refreshMenu() {
        statusItem.menu = buildMenu()
    }

    @objc private func handleStartStop() {
        toggleRecord()
    }

    private func toggleRecord() {
        if isTranscribing {
            return
        }
        if !isRecording {
            startRecording()
        } else {
            stopAndTranscribe()
        }
    }

    private func startRecording() {
        if isTranscribing { return }
        do {
            try recorder.start()
            isRecording = true
            recordStartAt = ProcessInfo.processInfo.systemUptime
            statusItem.button?.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "Recording")
            refreshMenu()
        } catch {
            notify("Microphone error", subtitle: error.localizedDescription)
        }
    }

    private func stopAndTranscribe() {
        // Enforce a minimum record time (~0.2s) to avoid too-short files on accidental double-trigger
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - recordStartAt
        if elapsed < 0.20 {
            Thread.sleep(forTimeInterval: 0.20 - elapsed)
        }
        isTranscribing = true
        let audioURL = recorder.stop()
        isRecording = false
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper")
        refreshMenu()
        guard let audioURL else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
               let size = attrs[.size] as? NSNumber {
                print("[Whisper] Audio file: \(audioURL.path) (\(size.intValue) bytes)")
            }
            DispatchQueue.main.async {
                self.notify("Transcribing…", subtitle: nil)
                self.startLoadingAnimation()
            }
            // Give the recorder a brief moment to finalize the file
            Thread.sleep(forTimeInterval: 0.2)
            // Ensure audio long enough (~0.1s at 16kHz mono 16-bit ~ 3200 bytes + header)
            if let attrs2 = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
               let size2 = attrs2[.size] as? NSNumber {
                if size2.intValue < 3600 {
                    DispatchQueue.main.async {
                        self.alert("Audio too short", message: "Captured less than 0.1s. Please speak for a moment before stopping.")
                        self.stopLoadingAnimation()
                    }
                    try? FileManager.default.removeItem(at: audioURL)
                    return
                }
            }
            do {
                let text = try self.transcriber.transcribeSync(audioURL: audioURL)
                print("[Whisper][Transcript] \(text)")
                DispatchQueue.main.async { AppSettings.shared.lastTranscript = text }
                var ok = PasteboardManager.paste(text: text, pressEnter: AppSettings.shared.pressEnterAfterPaste, preserveClipboard: AppSettings.shared.preserveClipboard)
                if AppSettings.shared.debugPasteToXcode {
                    if let xcode = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first {
                        xcode.activate(options: [.activateIgnoringOtherApps])
                        Thread.sleep(forTimeInterval: 0.3)
                        let ok2 = PasteboardManager.paste(text: text, pressEnter: false, preserveClipboard: false)
                        ok = ok || ok2
                    }
                }
                DispatchQueue.main.async { self.showTranscriptHUD(text) }
                if ok { DispatchQueue.main.async { self.notify("Pasted transcript", subtitle: nil) } }
                else   { DispatchQueue.main.async { self.notify("Copied transcript", subtitle: "Cmd+V to paste") } }
            } catch {
                DispatchQueue.main.async { self.alert("Transcription failed", message: error.localizedDescription) }
            }
            DispatchQueue.main.async { self.stopLoadingAnimation() }
            try? FileManager.default.removeItem(at: audioURL)
            self.isTranscribing = false
        }
    }

    @objc private func openPreferences() {
        if let wc = prefsWC {
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let vc = NSHostingController(rootView: PreferencesView())
        let w = NSWindow(contentViewController: vc)
        w.title = "Whisper Preferences"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.center()
        let wc = NSWindowController(window: w)
        self.prefsWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(self)
    }

    private func notify(_ title: String, subtitle: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        print("[Whisper] \(title)\(subtitle.map { ": \($0)" } ?? "")")
    }

    private func alert(_ title: String, message: String?) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.alertStyle = .warning
        alert.runModal()
        print("[Whisper][Error] \(title)\(message.map { ": \($0)" } ?? "")")
    }

    private func startLoadingAnimation() {
        guard let button = statusItem.button else { return }
        loadingAnimator?.stop()
        let animator = LoadingAnimator { [weak button] glyph in
            button?.title = glyph
        }
        loadingAnimator = animator
        animator.start()
    }

    private func stopLoadingAnimation() {
        loadingAnimator?.stop()
        statusItem.button?.title = ""
    }

    // Show transcript popup in dev mode
    private func showTranscriptHUD(_ text: String) {
        guard AppSettings.shared.debugShowPopup else { return }
        hud.show(text: text)
    }

    // Ensure banners show while app is frontmost
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
