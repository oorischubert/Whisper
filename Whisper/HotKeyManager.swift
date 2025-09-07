import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class HotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private let keyCode: UInt32

    init(keyCode: UInt32, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.handler = handler
        registerHotKey()
    }

    deinit {
        unregisterHotKey()
    }

    func registerHotKey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), { (next, event, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let mySelf = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            mySelf.handler()
            return noErr
        }, 1, &eventSpec, selfPtr, &eventHandler)

        var hotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: FourCharCode("WSPR"))), id: 1)
        RegisterEventHotKey(UInt32(keyCode), 0, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
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

    func setKeyCode(_ newKeyCode: UInt32) {
        unregisterHotKey()
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), { (next, event, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let mySelf = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            mySelf.handler()
            return noErr
        }, 1, &eventSpec, selfPtr, &eventHandler)

        var hotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: FourCharCode("WSPR"))), id: 1)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(newKeyCode), 0, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        self.hotKeyRef = ref
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
