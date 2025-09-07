import AVFoundation

final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var tempURL: URL?

    func start() throws {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        #endif

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent("whisper_\(UUID().uuidString).wav")
        tempURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = false
        rec.prepareToRecord()
        guard rec.record() else { throw NSError(domain: "Whisper", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"]) }
        self.recorder = rec
    }

    func stop() -> URL? {
        recorder?.stop()
        let url = tempURL
        recorder = nil
        tempURL = nil
        return url
    }
}
