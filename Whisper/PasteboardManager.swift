import AppKit
import Foundation

enum PasteboardManager {
    static func paste(text: String, pressEnter: Bool, preserveClipboard: Bool) -> Bool {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return true }

        let pb = NSPasteboard.general
        var previous: String?
        // For the very first paste of the app session, never preserve to avoid race on initial paste
        let effectivePreserve = preserveClipboard && !firstPaste
        if effectivePreserve {
            previous = pb.string(forType: .string)
        }

        pb.clearContents()
        pb.setString(sanitized, forType: .string)

        // Give the pasteboard a moment to commit before sending Cmd+V
        let commitDeadline = Date().addingTimeInterval(0.2)
        while Date() < commitDeadline {
            if pb.string(forType: .string) == sanitized { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        let okPaste = sendCmdV()
        var okEnter = true
        if okPaste && pressEnter {
            okEnter = sendEnter()
        }
        // Delay restoring previous clipboard until paste is likely completed.
        // Use a longer delay for the very first paste of the session.
        if effectivePreserve, let prev = previous {
            let delay: TimeInterval = firstPaste ? 0.7 : 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pb.clearContents()
                pb.setString(prev, forType: .string)
            }
        }
        if firstPaste { firstPaste = false }
        return okPaste && okEnter
    }

    private static var firstPaste = true

    private static func sendCmdV() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        let loc = CGEventTapLocation.cghidEventTap
        down?.post(tap: loc)
        up?.post(tap: loc)
        return true
    }

    private static func sendEnter() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let enterKey: CGKeyCode = 36 // kVK_Return
        let down = CGEvent(keyboardEventSource: src, virtualKey: enterKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: enterKey, keyDown: false)
        let loc = CGEventTapLocation.cghidEventTap
        down?.post(tap: loc)
        up?.post(tap: loc)
        return true
    }
}
