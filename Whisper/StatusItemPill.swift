import AppKit
import QuartzCore

/// The menu-bar presentation for Whisper's status item.
///
/// Idle, it's just the waveform icon and a click opens the menu. Depending on the
/// user's `StatusControlsMode` it can also host inline, one-press buttons — a
/// stop/start button and a cancel (✕) — so the common actions don't need a trip
/// through the menu. The icon stays a button too, so clicking it still opens the
/// full menu. The width change between states is animated rather than snapped.
/// While transcribing, the icon gently pulses its opacity to signal work in flight.
///
/// The buttons are plain template glyphs (they tint to the menu bar like every
/// other icon) — meaning is carried by the shapes: ▶ start, ■ stop, ✕ cancel.
@MainActor
final class StatusItemPill {
    enum Activity: Equatable { case idle, recording, transcribing }

    /// Clicking the waveform icon — the caller pops the menu.
    var onIconClick: () -> Void = {}
    /// The start/stop button (▶ while idle, ■ while recording).
    var onPrimary: () -> Void = {}
    /// The cancel (✕) button.
    var onCancel: () -> Void = {}

    private let statusItem: NSStatusItem
    private var activity: Activity = .idle
    private var controls: StatusControlsMode = .cancelOnly

    private let container = NSView()
    private let backdropButton = NSButton() // full-size click target behind the controls
    private let iconButton = NSButton()
    private let primaryButton = NSButton()
    private let cancelButton = NSButton()

    // Layout metrics. All buttons are `controlWidth` points wide. Kept tight so the
    // icon and its buttons sit close together, like the plain icon did. `pad` is the
    // breathing room at each end — small so the pill hugs the buttons.
    private let pad: CGFloat = 1
    private let gap: CGFloat = 3
    private let controlWidth: CGFloat = 16
    // The ✕ glyph reads as more inset than the play/stop glyph, so its gap to the icon
    // looks wider. Nudge it toward the icon so both sides of the icon look even.
    private let cancelOpticalNudge: CGFloat = 2

    private var transitionGeneration = 0
    private var isPulsing = false

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        configure()
    }

    // MARK: - Setup

    private func configure() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""

        container.wantsLayer = true
        container.autoresizingMask = [.width, .height] // follows the button through resizes
        button.addSubview(container)

        // A full-size click target behind everything: clicking any empty part of the
        // pill (or the icon) opens the menu, while the action buttons in front still
        // handle their own taps. Added first so it sits behind the controls.
        backdropButton.isBordered = false
        backdropButton.title = ""
        backdropButton.imagePosition = .imageOnly
        backdropButton.autoresizingMask = [.width, .height]
        backdropButton.target = self
        backdropButton.action = #selector(iconClicked)
        container.addSubview(backdropButton)

        configureIconButton()
        configure(button: primaryButton, accessibility: "Start recording", action: #selector(primaryClicked))
        configure(button: cancelButton, accessibility: "Cancel", action: #selector(cancelClicked))
        // Bold so the ✕ reads as substantial, but sized to match the play/stop glyph.
        cancelButton.image = symbolImage("xmark", point: 12, weight: .bold)

        primaryButton.isHidden = true
        cancelButton.isHidden = true

        let idleWidth = width(for: .idle, controls: controls)
        statusItem.length = idleWidth
        // Seed the container at the real size so the first layout is correct; after this
        // the autoresizing mask keeps it in step with the button on every width change.
        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        container.frame = NSRect(x: 0, y: 0, width: idleWidth, height: height)

        updateIcons()
        layoutControls()
    }

    private func configureIconButton() {
        iconButton.isBordered = false
        iconButton.bezelStyle = .regularSquare
        iconButton.imagePosition = .imageOnly
        iconButton.wantsLayer = true // so the transcribing pulse can animate its opacity
        // Pinned to the right edge: when the item's width changes the system keeps the
        // icon in place automatically, so it never jitters as buttons come and go.
        iconButton.autoresizingMask = [.minXMargin]
        iconButton.target = self
        iconButton.action = #selector(iconClicked)
        iconButton.setAccessibilityLabel("Whisper")
        container.addSubview(iconButton)
    }

    private func configure(button: NSButton, accessibility: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.wantsLayer = true // so pop-in/out can animate opacity and scale
        button.autoresizingMask = [.minXMargin] // pinned to the right edge like the icon
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibility)
        container.addSubview(button)
    }

    // MARK: - Public API

    func update(activity newActivity: Activity, controls newControls: StatusControlsMode, animated: Bool) {
        guard newActivity != activity || newControls != controls else { return }
        let before = visibleControls(activity, controls)
        activity = newActivity
        controls = newControls
        updateIcons()
        setPulsing(newActivity == .transcribing)

        let after = visibleControls(newActivity, newControls)
        let entering = after.subtracting(before)
        let leaving = before.subtracting(after)
        transition(entering: Array(entering), leaving: Array(leaving), animated: animated)
    }

    // MARK: - Clicks

    @objc private func iconClicked() { onIconClick() }
    @objc private func primaryClicked() { onPrimary() }
    @objc private func cancelClicked() { onCancel() }

    // MARK: - Visibility

    private func isPrimaryVisible(_ a: Activity, _ c: StatusControlsMode) -> Bool {
        // In Full mode the start/stop button is *always* present (disabled while
        // transcribing), so it can hold the right edge and never has to slide.
        c == .full
    }

    private func isCancelVisible(_ a: Activity, _ c: StatusControlsMode) -> Bool {
        (c == .cancelOnly || c == .full) && (a == .recording || a == .transcribing)
    }

    /// All elements in left-to-right order. The cancel button — the one that comes and
    /// goes — sits on the *left*, where the item grows and shrinks. The start/stop
    /// button (Full mode), which is always present, sits on the *right* of the icon so
    /// both it and the icon stay pinned to the menu bar's fixed right edge and hold
    /// still; only the cancel button animates in and out.
    private func orderedElements(_ a: Activity, _ c: StatusControlsMode) -> [(view: NSView, width: CGFloat)] {
        var items: [(NSView, CGFloat)] = []
        if isCancelVisible(a, c) { items.append((cancelButton, controlWidth)) }
        items.append((iconButton, controlWidth))
        if isPrimaryVisible(a, c) { items.append((primaryButton, controlWidth)) }
        return items
    }

    /// The visible control buttons — everything except the always-present icon.
    private func visibleControls(_ a: Activity, _ c: StatusControlsMode) -> Set<NSView> {
        Set(orderedElements(a, c).map { $0.view }).subtracting([iconButton])
    }

    // MARK: - Appearance

    private func updateIcons() {
        // The mic-badge variant signals that a recording is in progress.
        let recording = (activity == .recording)
        iconButton.image = symbolImage(recording ? "waveform.badge.mic" : "waveform", point: 15)

        primaryButton.image = symbolImage(recording ? "stop.fill" : "play.fill", point: 12)
        primaryButton.setAccessibilityLabel(recording ? "Stop and transcribe" : "Start recording")
        // Nothing to start or stop mid-transcription, so the button is inert (and dimmed)
        // there — but it stays put so the icon beside it doesn't have to move.
        primaryButton.isEnabled = (activity != .transcribing)
    }

    // MARK: - Pulse

    /// While transcribing, the icon breathes its opacity in and out. Removing the
    /// animation restores the icon to full opacity.
    private func setPulsing(_ on: Bool) {
        guard on != isPulsing else { return }
        isPulsing = on
        let key = "pulse"
        guard on else {
            iconButton.layer?.removeAnimation(forKey: key)
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.65
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconButton.layer?.add(pulse, forKey: key)
    }

    // MARK: - Transition

    /// The width of a menu-bar item is owned by the system, which relayouts the bar
    /// discretely and off our animation clock — animating `length` frame-by-frame
    /// stutters. Instead we change the width in one step and animate the buttons with
    /// Core Animation (GPU, vsync-locked): grow first then pop the newcomers in; on a
    /// shrink, pop the leavers out first, then collapse the width once they're gone.
    private func transition(entering: [NSView], leaving: [NSView], animated: Bool) {
        let target = width(for: activity, controls: controls)
        let current = statusItem.length

        guard animated else {
            entering.forEach { $0.layer?.removeAnimation(forKey: Self.popKey); $0.isHidden = false; $0.alphaValue = 1 }
            leaving.forEach { $0.layer?.removeAnimation(forKey: Self.popKey); $0.isHidden = true; $0.alphaValue = 1 }
            statusItem.length = target
            layoutControls()
            return
        }

        let duration: TimeInterval = 0.2
        transitionGeneration &+= 1

        if target > current {
            // Grow: open the space in one step, then pop the newcomers in.
            statusItem.length = target
            layoutControls()
            entering.forEach { popIn($0, duration: duration) }
            leaving.forEach { popOut($0, duration: duration) }
        } else if target < current {
            // Shrink: fade the leavers out while the remaining controls *slide* into the
            // spot they vacate — a touch slower than the fade — so the icon never lands on
            // a still-visible button. Collapse the width once the slide finishes.
            let slide: TimeInterval = 0.3
            NSAnimationContext.runAnimationGroup { context in
                context.duration = slide
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layoutControls(animated: true)
            }
            entering.forEach { popIn($0, duration: duration) }
            leaving.forEach { popOut($0, duration: duration) }
            let generation = transitionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + slide) { [weak self] in
                guard let self, self.transitionGeneration == generation else { return }
                self.statusItem.length = target
                self.layoutControls()
            }
        } else {
            // Same width: cross-fade in place.
            layoutControls()
            entering.forEach { popIn($0, duration: duration) }
            leaving.forEach { popOut($0, duration: duration) }
        }
    }

    private static let popKey = "pop"

    /// Fades and scales a control in.
    private func popIn(_ view: NSView, duration: TimeInterval) {
        view.isHidden = false
        view.alphaValue = 1
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.popKey)
        let group = CAAnimationGroup()
        group.animations = [basic("opacity", from: 0, to: 1), basic("transform.scale", from: 0.4, to: 1)]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: Self.popKey)
    }

    /// Fades and scales a control out, hiding it when the animation completes.
    private func popOut(_ view: NSView, duration: TimeInterval) {
        guard let layer = view.layer else { view.isHidden = true; return }
        layer.removeAnimation(forKey: Self.popKey)
        let group = CAAnimationGroup()
        group.animations = [basic("opacity", from: 1, to: 0), basic("transform.scale", from: 1, to: 0.4)]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in
            view?.isHidden = true
            view?.layer?.removeAnimation(forKey: Self.popKey)
            view?.alphaValue = 1
        }
        layer.add(group, forKey: Self.popKey)
        CATransaction.commit()
    }

    private func basic(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    // MARK: - Layout

    /// Lays the elements out anchored to the *right* edge: the icon sits at the far
    /// right (the menu bar's fixed edge, so it never moves), and control buttons fill
    /// leftward from there.
    ///
    /// Positions use the *live* container width, never the requested `statusItem.length`.
    /// After a width change the button's bounds lag the requested length by a frame; the
    /// autoresizing masks absorb the resize so every element stays put — laying out from
    /// the not-yet-applied target width instead is exactly what made the icon shake.
    private func layoutControls(animated: Bool = false) {
        let height = container.bounds.height
        let totalWidth = container.bounds.width > 0 ? container.bounds.width : statusItem.length

        backdropButton.frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)

        var rightEdge = totalWidth - pad
        for item in orderedElements(activity, controls).reversed() { // right-to-left
            let x = rightEdge - item.width
            // Position against the *live* width (never the pending target) so a mid-resize
            // frame lands each element on its current spot; the autoresizing masks then
            // carry them through the resize without a jump.
            let nudge = (item.view === cancelButton) ? cancelOpticalNudge : 0
            let frame = centered(x: x + nudge, width: item.width, height: controlWidth, in: height)
            if animated {
                item.view.animator().frame = frame
            } else {
                item.view.frame = frame
            }
            rightEdge = x - gap
        }
    }

    private func centered(x: CGFloat, width: CGFloat, height: CGFloat, in containerHeight: CGFloat) -> NSRect {
        NSRect(x: x, y: (containerHeight - height) / 2, width: width, height: height)
    }

    private func width(for activity: Activity, controls: StatusControlsMode) -> CGFloat {
        let elements = orderedElements(activity, controls)
        let content = elements.reduce(CGFloat(0)) { $0 + $1.width }
        let gaps = CGFloat(max(0, elements.count - 1)) * gap
        return pad + content + gaps + pad
    }

    // MARK: - Symbols

    private func symbolImage(_ name: String, point: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: point, weight: weight)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }
}
