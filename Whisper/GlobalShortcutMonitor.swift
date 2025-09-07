import AppKit

final class GlobalShortcutMonitor {
    private var globalMonitor: Any?
    private let handler: () -> Void
    private var keyCode: UInt16
    private var modifiers: NSEvent.ModifierFlags
    private var lastTriggerAt: TimeInterval = 0

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
        start()
    }

    deinit { stop() }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.process(event: event)
        }
    }

    func stop() {
        if let gm = globalMonitor { NSEvent.removeMonitor(gm) }
        globalMonitor = nil
    }

    private func process(event: NSEvent) {
        guard event.type == .keyDown else { return }
        // Require exact subset: our modifiers must be present (ignore caps/num flags)
        let normalized = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if event.keyCode == keyCode && normalized == modifiers.intersection([.control, .option, .command, .shift]) {
            // Throttle rapid repeats
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTriggerAt < 0.35 { return }
            lastTriggerAt = now
            handler()
        }
    }
}
