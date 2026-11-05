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
        // Metering is how `waitUntilLive` tells a waking mic from a working one.
        rec.isMeteringEnabled = true
        rec.prepareToRecord()
        guard rec.record() else { throw NSError(domain: "Whisper", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"]) }
        self.recorder = rec
    }

    /// Returns once the mic is actually delivering sound, or after `timeout`.
    ///
    /// Bluetooth headsets like AirPods take about a second to switch into mic mode,
    /// and until then the recording is pure silence. Cueing the user to speak before
    /// that is what clipped the first words off a transcript.
    @discardableResult
    func waitUntilLive(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let recorder, recorder.isRecording else { return false }
            recorder.updateMeters()
            // A dead input meters at the -160 dB floor; any real mic, even in a quiet
            // room, picks up enough noise to sit far above this.
            if recorder.peakPower(forChannel: 0) > -100 { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }

    func stop() -> URL? {
        recorder?.stop()
        let url = tempURL
        recorder = nil
        tempURL = nil
        return url
    }
}
