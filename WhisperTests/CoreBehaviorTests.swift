import XCTest
import AppKit
@testable import Whisper

final class CoreBehaviorTests: XCTestCase {
    func testActivityFlagsDescribeEveryState() {
        XCTAssertFalse(AppActivity.idle.isRecording)
        XCTAssertFalse(AppActivity.idle.isTranscribing)
        XCTAssertTrue(AppActivity.recording(startedAt: Date()).isRecording)
        XCTAssertFalse(AppActivity.recording(startedAt: Date()).isTranscribing)
        XCTAssertTrue(AppActivity.transcribing.isTranscribing)
    }

    func testMisclickRecordingSwallowsAnEmptyTranscript() {
        // Tapped and released with nothing said: no alert, whichever engine ran.
        XCTAssertFalse(TranscriptionFailure.deservesAlert(TranscriberError.outputMissing, recordedFor: 0.2))
        XCTAssertFalse(TranscriptionFailure.deservesAlert(
            TranscriberError.outputMissing,
            recordedFor: TranscriptionFailure.misclickDuration - 0.01
        ))
    }

    func testDeliberateRecordingReportsAnEmptyTranscript() {
        // Long enough to have spoken, so silence coming back is worth knowing about.
        // Bound to the constant so retuning it cannot silently move the boundary.
        XCTAssertTrue(TranscriptionFailure.deservesAlert(
            TranscriberError.outputMissing,
            recordedFor: TranscriptionFailure.misclickDuration
        ))
        XCTAssertTrue(TranscriptionFailure.deservesAlert(TranscriberError.outputMissing, recordedFor: 30.0))
    }

    func testRealFailuresAlwaysReportHoweverBriefTheRecording() {
        let brief: TimeInterval = 0.2
        XCTAssertTrue(TranscriptionFailure.deservesAlert(TranscriberError.modelNotDownloaded("Base"), recordedFor: brief))
        XCTAssertTrue(TranscriptionFailure.deservesAlert(TranscriberError.timedOut, recordedFor: brief))
        XCTAssertTrue(TranscriptionFailure.deservesAlert(
            NSError(domain: "Whisper", code: -2, userInfo: [NSLocalizedDescriptionKey: "API rejected the key"]),
            recordedFor: brief
        ))
    }

    func testMultipartBodyIncludesSelectedFieldsAndAudio() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try Data([0x01, 0x02, 0x03]).write(to: audioURL)

        let body = try MultipartFormDataBuilder.build(
            boundary: "test-boundary",
            audioURL: audioURL,
            model: "test-model",
            language: "he"
        )
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ntest-model"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nhe"))
        XCTAssertTrue(text.contains("filename=\"\(audioURL.lastPathComponent)\""))
        XCTAssertTrue(text.hasSuffix("\r\n--test-boundary--\r\n"))
    }

    func testMultipartBodyOmitsAutomaticLanguage() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try Data().write(to: audioURL)

        let body = try MultipartFormDataBuilder.build(
            boundary: "test-boundary",
            audioURL: audioURL,
            model: "test-model",
            language: "auto"
        )

        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("name=\"language\""))
    }

    func testPasteboardSnapshotRestoresRichItems() throws {
        let pasteboard = NSPasteboard(name: .init("WhisperTests.\(UUID().uuidString)"))
        let customType = NSPasteboard.PasteboardType("com.whisper.tests.custom")
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([0xCA, 0xFE]), forType: customType)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([original]))

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let transcriptChangeCount = pasteboard.changeCount

        XCTAssertTrue(snapshot.restore(to: pasteboard, ifUnchangedSince: transcriptChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: customType), Data([0xCA, 0xFE]))
    }

    func testPasteboardSnapshotDoesNotOverwriteNewClipboardContent() {
        let pasteboard = NSPasteboard(name: .init("WhisperTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("new user content", forType: .string)

        XCTAssertFalse(snapshot.restore(to: pasteboard, ifUnchangedSince: transcriptChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "new user content")
    }

    // MARK: - Local models

    func testLegacyPythonModelNamesMigrateToCatalogModels() {
        XCTAssertEqual(LocalModel.migratedID(from: "tiny"), "openai_whisper-tiny")
        XCTAssertEqual(LocalModel.migratedID(from: "base"), "openai_whisper-base")
        XCTAssertEqual(LocalModel.migratedID(from: "small"), "openai_whisper-small")
        XCTAssertEqual(LocalModel.migratedID(from: "medium"), "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(LocalModel.migratedID(from: "large"), "openai_whisper-large-v3_947MB")
    }

    func testMigrationKeepsCatalogIDsAndFallsBackToDefault() {
        for model in LocalModel.catalog {
            XCTAssertEqual(LocalModel.migratedID(from: model.id), model.id)
        }
        XCTAssertEqual(LocalModel.migratedID(from: nil), LocalModel.defaultID)
        XCTAssertEqual(LocalModel.migratedID(from: ""), LocalModel.defaultID)
        XCTAssertEqual(LocalModel.migratedID(from: "something-unknown"), LocalModel.defaultID)
        XCTAssertNotNil(LocalModel.model(withID: LocalModel.defaultID))
    }

    func testCatalogIDsAreUniqueWithExactlyOneRecommendation() {
        let ids = LocalModel.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(LocalModel.catalog.filter(\.isRecommended).count, 1)
    }

    func testAModelWithoutTheReadyMarkerIsNotInstalled() {
        XCTAssertFalse(LocalModelStorage.isInstalled("not-a-real-model-\(UUID().uuidString)"))
    }
}
