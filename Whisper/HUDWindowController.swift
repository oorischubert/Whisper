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
        let vev = NSVisualEffectView(frame: contentRect)
        vev.material = .hudWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 12

        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false

        vev.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: vev.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: vev.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: vev.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: vev.bottomAnchor, constant: -16)
        ])

        panel.contentView = vev
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

