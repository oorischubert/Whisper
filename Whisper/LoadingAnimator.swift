import AppKit

final class LoadingAnimator {
    private var timer: Timer?
    private let frames = ["⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓"]
    private var index = 0
    private let update: (String) -> Void

    init(update: @escaping (String) -> Void) {
        self.update = update
    }

    func start() {
        stop()
        update(frames[index])
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.index = (self.index + 1) % self.frames.count
            self.update(self.frames[self.index])
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        index = 0
    }
}

