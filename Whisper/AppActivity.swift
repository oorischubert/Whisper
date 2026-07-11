import Foundation

enum AppActivity: Equatable {
    case idle
    case recording(startedAt: Date)
    case transcribing

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isTranscribing: Bool {
        self == .transcribing
    }
}
