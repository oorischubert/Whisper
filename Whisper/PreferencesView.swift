import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import ApplicationServices
import UserNotifications
import ServiceManagement

struct PreferencesView: View {
    @StateObject private var settings = AppSettings.shared

    private let models = ["tiny", "base", "small", "medium", "large"]
    private let languages: [(label: String, code: String)] = [
        ("Auto (detect)", "auto"),
        ("English", "en"),
        ("Hebrew", "he"),
        ("Arabic", "ar"),
        ("French", "fr"),
        ("German", "de"),
        ("Spanish", "es"),
        ("Russian", "ru"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Chinese (Mandarin)", "zh"),
        ("Japanese", "ja"),
        ("Korean", "ko"),
        ("Hindi", "hi"),
        ("Turkish", "tr")
    ]
    @State private var tab: PrefsTab
    private let labelWidth: CGFloat = 160

    init(initialTab: PrefsTab = .transcription) {
        _tab = State(initialValue: initialTab)
    }

    enum PrefsTab: String, CaseIterable, Identifiable { case setup, transcription, pasting, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .setup: return "Setup"
            case .transcription: return "Transcription"
            case .pasting: return "Pasting"
            case .general: return "General"
            }
        }
        var symbol: String {
            switch self {
            case .setup: return "checkmark.circle"
            case .transcription: return "waveform"
            case .pasting: return "rectangle.and.paperclip"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .frame(width: 820, height: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(PrefsTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol)
                        Text(t.title)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(tab == t ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 200)
        .background(.ultraThinMaterial)
    }

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                Text(tab.title)
                    .font(.title3).bold()
                Spacer()
            }
            ScrollView {
                Group {
                    switch tab {
                    case .setup:         setupView
                    case .transcription: transcriptionView
                    case .pasting:       pastingView
                    case .general:       generalView
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityEnabled = AXIsProcessTrusted()
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(
                title: "Ready when you are",
                subtitle: "Whisper only needs access to the capabilities you choose to use."
            ) {
                PermissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: microphoneDetail,
                    isReady: microphoneStatus == .authorized,
                    actionTitle: microphoneStatus == .authorized ? nil : "Allow"
                ) {
                    requestMicrophoneAccess()
                }

                Divider()

                PermissionRow(
                    symbol: "keyboard.fill",
                    title: "Accessibility",
                    detail: accessibilityEnabled
                        ? "Ready to paste transcripts into other apps."
                        : "Required for automatic Command–V pasting.",
                    isReady: accessibilityEnabled,
                    actionTitle: accessibilityEnabled ? nil : "Open Settings"
                ) {
                    HotKeyManager.requestAccessibilityIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshPermissionStatuses() }
                }

                Divider()

                PermissionRow(
                    symbol: "bell.badge.fill",
                    title: "Notifications",
                    detail: notificationDetail,
                    isReady: notificationStatus == .authorized || notificationStatus == .provisional,
                    actionTitle: notificationStatus == .notDetermined ? "Enable" : nil
                ) {
                    requestNotificationAccess()
                }
            }

            SectionCard(title: "Transcription engine") {
                PermissionRow(
                    symbol: settings.useAPI ? "cloud.fill" : "laptopcomputer",
                    title: settings.useAPI ? "OpenAI API" : "Local Whisper",
                    detail: engineReadiness.detail,
                    isReady: engineReadiness.ready,
                    actionTitle: engineReadiness.ready ? nil : "Configure"
                ) {
                    tab = .transcription
                }
            }

            HStack {
                Text("You can revisit this checklist from Settings at any time.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button(settings.hasCompletedOnboarding ? "Done" : "Finish Setup") {
                    settings.hasCompletedOnboarding = true
                    tab = .transcription
                }
                .buttonStyle(.borderedProminent)
                .disabled(microphoneStatus != .authorized)
            }
        }
        .onAppear { refreshPermissionStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatuses()
        }
    }

    private var microphoneDetail: String {
        switch microphoneStatus {
        case .authorized: return "Ready to record audio."
        case .denied, .restricted: return "Blocked. Enable access in Privacy & Security settings."
        case .notDetermined: return "Required to record speech for transcription."
        @unknown default: return "Microphone permission status is unavailable."
        }
    }

    private var notificationDetail: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "Completion and error alerts are enabled."
        case .denied: return "Disabled. The menu-bar status still works without alerts."
        case .notDetermined: return "Optional alerts when a transcript is ready."
        @unknown default: return "Notification permission status is unavailable."
        }
    }

    private var engineReadiness: (ready: Bool, detail: String) {
        if settings.useAPI {
            let ready = !(settings.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (ready, ready ? "API key is stored securely in Keychain." : "Add an API key to use cloud transcription.")
        }
        guard let path = settings.resolvePythonExecutable() else {
            return (false, "Choose a Python installation containing openai-whisper.")
        }
        return (
            FileManager.default.isExecutableFile(atPath: path),
            FileManager.default.isExecutableFile(atPath: path)
                ? "Python is configured. Use Test to verify the Whisper package."
                : "The configured Python path is not executable."
        )
    }

    private func requestMicrophoneAccess() {
        if microphoneStatus == .denied || microphoneStatus == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
        }
    }

    private func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
        }
    }

    private func refreshPermissionStatuses() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityEnabled = AXIsProcessTrusted()
        UNUserNotificationCenter.current().getNotificationSettings { status in
            DispatchQueue.main.async { notificationStatus = status.authorizationStatus }
        }
    }

    private var transcriptionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Engine", subtitle: "Choose between the OpenAI API or a local Python-based Whisper.") {
                Toggle("Use OpenAI API (instead of local Whisper CLI)", isOn: $settings.useAPI)

                if settings.useAPI {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("API Key").frame(width: labelWidth, alignment: .trailing)
                            SecureField("sk-...", text: Binding(
                                get: { settings.apiKey ?? "" },
                                set: { settings.apiKey = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("API Model").frame(width: labelWidth, alignment: .trailing)
                            TextField("whisper-1", text: $settings.apiModel)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Local Model").frame(width: labelWidth, alignment: .trailing)
                            Picker("", selection: $settings.localModel) {
                                ForEach(models, id: \.self) { Text($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        HStack {
                            Text("Python Executable").frame(width: labelWidth, alignment: .trailing)
                            TextField("/opt/homebrew/bin/python3", text: $settings.pythonExecutablePath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Browse…") { browseForPython() }
                            Button("Detect") { detectPython() }
                            Button(testPythonInProgress ? "Testing…" : "Test") { testPython() }
                                .disabled(testPythonInProgress)
                        }
                        Text("Tip: Point to your env’s Python (e.g., ~/miniconda3/envs/whisper/bin/python) so the app runs \"python -m whisper\" inside it.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        if let tmsg = testPythonMessage {
                            HStack {
                                Spacer()
                                Text(tmsg)
                                    .foregroundColor(testPythonColor)
                                    .font(.footnote)
                            }
                        }
                        if let msg = detectMessage {
                            HStack {
                                Spacer()
                                Text(msg)
                                    .foregroundColor(detectMessageColor)
                                    .font(.footnote)
                            }
                        }
                    }
                }
            }

            SectionCard(title: "Language", subtitle: "Leave as “auto” to let Whisper detect the language.") {
                HStack {
                    Text("Language").frame(width: labelWidth, alignment: .trailing)
                    Picker("", selection: Binding(
                        get: { settings.language ?? "auto" },
                        set: { settings.language = $0 }
                    )) {
                        ForEach(languages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu) // scrollable menu on macOS
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Spacer(minLength: 0)
                }
            }

            SectionCard(title: "Last Transcript", subtitle: "Copied to your clipboard with one click.") {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(settings.lastTranscript.isEmpty ? "(none yet)" : settings.lastTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                    }
                    .frame(height: 140)

                    HStack {
                        Spacer()
                        Button("Copy to Clipboard") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(settings.lastTranscript, forType: .string)
                        }
                        .disabled(settings.lastTranscript.isEmpty)
                    }
                }
            }
        }
    }

    private var pastingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Pasting Behavior") {
                Toggle("Press Enter after paste (dangerous)", isOn: $settings.pressEnterAfterPaste)
                Toggle("Preserve existing clipboard", isOn: $settings.preserveClipboard)
                Toggle("Debug: bring Xcode to front before pasting", isOn: $settings.debugPasteToXcode)
                Toggle("Debug: show popup with transcript", isOn: $settings.debugShowPopup)
            }

            SectionCard(title: "Accessibility", subtitle: "Grant access so the app can paste into other apps.") {
                HStack {
                    Text("Accessibility Settings").frame(width: labelWidth, alignment: .trailing)
                    Button("Open…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    private var generalView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if #available(macOS 13.0, *) {
                    Text(launchAtLoginDetail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            SectionCard(title: "Hotkey", subtitle: "Choose the system-wide shortcut to trigger transcription.") {
                HStack {
                    Text("Hotkey").frame(width: labelWidth, alignment: .trailing)
                    Text(displayHotkey(code: settings.comboKeyCode, mods: settings.comboModifiers))
                    Spacer()
                    Button("Change…") { isCapturingHotkey = true }
                }
                .overlay(hotkeyCaptureOverlay)
                .allowsHitTesting(!isCapturingHotkey)
            }
        }
    }

    private var launchAtLoginDetail: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "Whisper will start when you log in."
            case .requiresApproval: return "Approval is required in Login Items settings."
            case .notRegistered: return "Whisper is not registered as a login item."
            case .notFound: return "Login-item registration is unavailable for this build."
            @unknown default: return "Login-item status is unavailable."
            }
        }
        return ""
    }

    private func browseForPython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Python executable"
        if panel.runModal() == .OK, let url = panel.url {
            settings.updatePythonPath(with: url)
        }
    }

    @State private var detectMessage: String?
    @State private var detectMessageColor: Color = .secondary
    @State private var testPythonMessage: String?
    @State private var testPythonColor: Color = .secondary
    @State private var testPythonInProgress: Bool = false

    private func detectPython() {
        if let path = AppSettings.shared.resolvePythonExecutable() {
            settings.pythonExecutablePath = path
            detectMessageColor = .green
            detectMessage = "Found: \(path)"
        } else {
            detectMessageColor = .red
            detectMessage = "Could not find Python (python3). Install Python and openai-whisper, or browse to your env's Python."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { detectMessage = nil }
    }

    private func testPython() {
        guard let pythonPath = AppSettings.shared.resolvePythonExecutable() else {
            testPythonColor = .red
            testPythonMessage = "Set a valid Python executable first."
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { testPythonMessage = nil }
            return
        }
        testPythonInProgress = true
        testPythonMessage = "Testing…"
        testPythonColor = .secondary
        DispatchQueue.global(qos: .userInitiated).async {
            let code = """
import sys, traceback
print("PY:" + sys.executable)
try:
    import whisper as m
    print("WH:" + str(getattr(m, "__file__", "")))
    print("OK")
except Exception as e:
    print("ERR:" + str(e))
    traceback.print_exc()
"""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            proc.arguments = ["-c", code]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var resultText = ""
            do {
                try AppSettings.shared.withWhisperAccess {
                    try proc.run()
                }
            } catch {
                resultText = "Launch failed: \(error.localizedDescription)"
            }
            if proc.isRunning { proc.waitUntilExit() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.testPythonInProgress = false
                let text = resultText.isEmpty ? output : (resultText + "\n" + output)
                let lines = text.split(separator: "\n").map(String.init)
                var pyPath: String?
                var whPath: String?
                var hasOK = false
                var errLine: String?
                for line in lines {
                    if line.hasPrefix("PY:") { pyPath = String(line.dropFirst(3)) }
                    if line.hasPrefix("WH:") { whPath = String(line.dropFirst(3)) }
                    if line.hasPrefix("ERR:") { errLine = String(line.dropFirst(4)) }
                    if line.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" { hasOK = true }
                }
                if hasOK {
                    self.testPythonColor = .green
                    self.testPythonMessage = "OK — Python: \(pyPath ?? pythonPath) | whisper: \(whPath ?? "<not found>")"
                } else {
                    self.testPythonColor = .red
                    let err = errLine ?? lines.last ?? "Unknown error"
                    self.testPythonMessage = "Failed — \(err)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.testPythonMessage = nil }
            }
        }
    }

    @State private var isCapturingHotkey = false
    @State private var hotkeyMonitorKeyDown: Any?
    @State private var hotkeyMonitorFlags: Any?
    @State private var liveMods: NSEvent.ModifierFlags = []
    @State private var liveKey: UInt16?

    private var hotkeyCaptureOverlay: some View {
        Group {
            if isCapturingHotkey {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 36, weight: .semibold))
                        Text("Set Hotkey")
                            .font(.title2).bold()
                        Text("Press a key combination. Esc to cancel.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                            .frame(height: 56)
                            .overlay(
                                Text(symbolHotkey(mods: liveMods, code: liveKey))
                                    .font(.title3.monospaced())
                                    .padding(.horizontal, 16)
                                    .lineLimit(1)
                            )
                            .padding(.top, 4)

                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(14)
                    .shadow(radius: 20, y: 8)
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.easeInOut(duration: 0.15), value: isCapturingHotkey)
                .onAppear { startCapturingHotkey() }
                .onDisappear { stopCapturingHotkey() }
            }
        }
    }

    private func startCapturingHotkey() {
        liveMods = []
        liveKey = nil

        hotkeyMonitorFlags = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            let normalized = event.modifierFlags.intersection([.control, .option, .command, .shift])
            liveMods = normalized
            return event
        }

        hotkeyMonitorKeyDown = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // ESC
                stopCapturingHotkey()
                return nil
            }
            let normalized = event.modifierFlags.intersection([.control, .option, .command, .shift])
            liveMods = normalized
            liveKey = event.keyCode
            if !normalized.isEmpty {
                settings.comboKeyCode = event.keyCode
                settings.comboModifiers = normalized
                stopCapturingHotkey()
                return nil
            }
            return nil
        }
    }

    private func stopCapturingHotkey() {
        if let m = hotkeyMonitorKeyDown { NSEvent.removeMonitor(m) }
        if let m = hotkeyMonitorFlags { NSEvent.removeMonitor(m) }
        hotkeyMonitorKeyDown = nil
        hotkeyMonitorFlags = nil
        isCapturingHotkey = false
    }

    private func displayHotkey(code: UInt16, mods: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("Ctrl") }
        if mods.contains(.option) { parts.append("Opt") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.command) { parts.append("Cmd") }
        let keyName = Self.keyDisplayName(for: code)
        parts.append(keyName)
        return parts.joined(separator: " + ")
    }

    private func symbolHotkey(mods: NSEvent.ModifierFlags, code: UInt16?) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        if let code {
            let name = Self.keyDisplayName(for: code)
            s += (s.isEmpty ? "" : " ") + name
        }
        return s.isEmpty ? "Waiting…" : s
    }

    static func keyDisplayName(for code: UInt16) -> String {
        switch code {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 13: return "W"
        case 12: return "Q"
        case 14: return "E"
        case 15: return "R"
        case 35: return "P"
        case 31: return "O"
        case 34: return "I"
        case 32: return "U"
        case 17: return "T"
        case 16: return "Y"
        case 49: return "Space"
        case 53: return "Esc"
        default: return "Key \(code)"
        }
    }

    private struct PermissionRow: View {
        let symbol: String
        let title: String
        let detail: String
        let isReady: Bool
        let actionTitle: String?
        let action: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isReady ? Color.green.opacity(0.14) : Color.orange.opacity(0.14))
                    Image(systemName: symbol)
                        .foregroundColor(isReady ? .green : .orange)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).fontWeight(.medium)
                        Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(isReady ? .green : .orange)
                            .accessibilityLabel(isReady ? "Ready" : "Needs attention")
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                if let actionTitle {
                    Button(actionTitle, action: action)
                }
            }
        }
    }

    // MARK: - Section Card

    private struct SectionCard<Content: View>: View {
        let title: String
        let subtitle: String?
        @ViewBuilder var content: Content

        init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.subtitle = subtitle
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                content
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 2)
            )
        }
    }
}
