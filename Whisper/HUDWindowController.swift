import AppKit

final class HUDWindowController: NSWindowController {
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 140)
        let panel = NSPanel(contentRect: contentRect, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false

        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false

        // Container that hosts the label with consistent insets across styles.
        let container = NSView(frame: contentRect)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])

        if #available(macOS 26.0, *) {
            // Apple's Liquid Glass surface.
            let glass = NSGlassEffectView(frame: contentRect)
            glass.cornerRadius = 18
            glass.contentView = container
            panel.contentView = glass
        } else {
            let vev = NSVisualEffectView(frame: contentRect)
            vev.material = .hudWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = 14
            container.autoresizingMask = [.width, .height]
            vev.addSubview(container)
            panel.contentView = vev
        }

        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(text: String, duration: TimeInterval = 4.0) {
        hideWorkItem?.cancel()
        label.stringValue = text
        if let screen = NSScreen.main {
            let size = window?.frame.size ?? .zero
            let x = screen.visibleFrame.midX - (size.width / 2)
            let y = screen.visibleFrame.midY - (size.height / 2)
            window?.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window?.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.window?.orderOut(nil) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

