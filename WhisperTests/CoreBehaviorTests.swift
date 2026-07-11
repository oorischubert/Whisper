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
}
