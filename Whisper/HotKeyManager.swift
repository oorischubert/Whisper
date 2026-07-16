import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Registers a bare (modifier-free) system-wide hotkey via Carbon.
///
/// Chosen over `GlobalShortcutMonitor` for the mic key because it *consumes* the key —
/// it never reaches the focused app — and needs no Accessibility or Input Monitoring
/// permission, whereas `NSEvent.addGlobalMonitorForEvents` requires Accessibility.
final class HotKeyManager {
    enum RegistrationError: LocalizedError {
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            "Another app is already using this key."
        }
    }

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private let keyCode: UInt32

    init(keyCode: UInt32, handler: @escaping () -> Void) throws {
        self.keyCode = keyCode
        self.handler = handler
        try registerHotKey()
    }

    deinit {
        unregisterHotKey()
    }

    private func registerHotKey() throws {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), { (next, event, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let mySelf = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            mySelf.handler()
            return noErr
        }, 1, &eventSpec, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: FourCharCode("WSPR"))), id: 1)
        let status = RegisterEventHotKey(keyCode, 0, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            unregisterHotKey()
            throw RegistrationError.registrationFailed(status)
        }
    }

    func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    static func requestAccessibilityIfNeeded() {
        // Required to send synthetic key events for paste; this opens System Settings prompt if disabled
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}

private func FourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for char in string.utf16 {
        result = (result << 8) + UInt32(char)
    }
    return result
}
