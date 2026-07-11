import AppKit
import ApplicationServices

struct PasteboardSnapshot {
    struct Item {
        let values: [NSPasteboard.PasteboardType: Data]
    }

    let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }))
        }
        return PasteboardSnapshot(items: items)
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        let restoredItems: [NSPasteboardItem] = items.map { snapshot in
            let item = NSPasteboardItem()
            snapshot.values.forEach { type, data in item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        guard !restoredItems.isEmpty else { return true }
        return pasteboard.writeObjects(restoredItems)
    }
}

enum PasteboardManager {
    static func paste(text: String, pressEnter: Bool, preserveClipboard: Bool) -> Bool {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PasteboardSnapshot.capture(from: pasteboard) : nil
        pasteboard.clearContents()
        guard pasteboard.setString(sanitized, forType: .string) else { return false }
        let transcriptChangeCount = pasteboard.changeCount

        let pasted = sendCommandV()
        let submitted = !pressEnter || (pasted && sendEnter())

        // If pasting is unavailable, leave the transcript on the clipboard as a safe fallback.
        if pasted, let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                snapshot.restore(to: pasteboard, ifUnchangedSince: transcriptChangeCount)
            }
        }
        return pasted && submitted
    }

    private static func sendCommandV() -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func sendEnter() -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
