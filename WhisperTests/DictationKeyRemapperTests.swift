import XCTest
@testable import Whisper

/// Covers the pure `UserKeyMapping` model only. The real `--set` is deliberately not
/// exercised: it would remap the developer's live keyboard.
final class DictationKeyRemapperTests: XCTestCase {

    // A foreign mapping we must never disturb: caps lock → escape.
    private let capsToEsc = KeyMapping(src: 0x700000039, dst: 0x700000029)

    // MARK: - Parsing

    /// hidutil prints `(null)` when the property has never been set, and `()` once it
    /// has been cleared. Both mean "no mappings".
    func testParseTreatsNullAndEmptyArrayAsNoMappings() throws {
        XCTAssertEqual(try UserKeyMapping.parse("(null)"), [])
        XCTAssertEqual(try UserKeyMapping.parse("(\n)"), [])
        XCTAssertEqual(try UserKeyMapping.parse(""), [])
        XCTAssertEqual(try UserKeyMapping.parse("  \n "), [])
    }

    /// Verbatim `hidutil property --get UserKeyMapping` output. This is the test that
    /// catches the OpenStep trap: the plist format has no number type, so both values
    /// decode as String rather than NSNumber.
    func testParseReadsRealHidutilOutput() throws {
        let output = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771176;
                HIDKeyboardModifierMappingSrc = 51539607759;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """

        XCTAssertEqual(try UserKeyMapping.parse(output), [
            .whisper,
            KeyMapping(src: 30064771129, dst: 30064771113),
        ])
    }

    /// macOS 27 prints a per-service table instead of one plist. Rows can disagree
    /// (some services never take the value), so the result is their union.
    func testParseReadsMacOS27ServiceTable() throws {
        let output = """
        RegistryID  Key                   Value
        10000093c   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771176;
                HIDKeyboardModifierMappingSrc = 51539607759;
            }
        )
        100000aa4   UserKeyMapping   (null)
        1000007bd   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771176;
                HIDKeyboardModifierMappingSrc = 51539607759;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """

        XCTAssertEqual(try UserKeyMapping.parse(output), [.whisper, capsToEsc])
    }

    func testParseReadsMacOS27ServiceTableWithNoMappings() throws {
        let output = """
        RegistryID  Key                   Value
        10000093c   UserKeyMapping   (null)
        1000007bd   UserKeyMapping   (
        )
        """
        XCTAssertEqual(try UserKeyMapping.parse(output), [])
    }

    func testParseThrowsOnMalformedServiceTableRow() {
        let output = """
        RegistryID  Key                   Value
        10000093c   UserKeyMapping   ( { SomeOtherKey = 1; } )
        """
        XCTAssertThrowsError(try UserKeyMapping.parse(output))
    }

    func testParseAcceptsHexValues() throws {
        let output = """
        (
                {
                HIDKeyboardModifierMappingDst = 0x700000068;
                HIDKeyboardModifierMappingSrc = 0xC000000CF;
            }
        )
        """
        XCTAssertEqual(try UserKeyMapping.parse(output), [.whisper])
    }

    /// Unrecognized input must throw, never yield []. Callers merge onto the parse
    /// result and write it back, so a silent [] would erase another tool's mappings.
    func testParseThrowsOnUnrecognizedInputRatherThanReportingNoMappings() {
        XCTAssertThrowsError(try UserKeyMapping.parse("not a plist at all {{{"))
        XCTAssertThrowsError(try UserKeyMapping.parse("( { SomeOtherKey = 1; } )"))
    }

    // MARK: - Merging

    func testMergedAddsMappingWhenNoneExist() {
        XCTAssertEqual(UserKeyMapping.merged([], adding: .whisper), [.whisper])
    }

    func testMergedPreservesForeignMappings() {
        XCTAssertEqual(
            UserKeyMapping.merged([capsToEsc], adding: .whisper),
            [capsToEsc, .whisper]
        )
    }

    func testMergedIsIdempotent() {
        let once = UserKeyMapping.merged([capsToEsc], adding: .whisper)
        XCTAssertEqual(UserKeyMapping.merged(once, adding: .whisper), once)
    }

    func testMergedReplacesDifferentMappingOfSameSourceKey() {
        let dictationToF5 = KeyMapping(src: UserKeyMapping.dictationSrc, dst: 0x70000003E)
        XCTAssertEqual(
            UserKeyMapping.merged([dictationToF5], adding: .whisper),
            [.whisper]
        )
    }

    // MARK: - Removing

    func testRemovingDeletesOnlyOurMappingAndLeavesForeignOnes() {
        let existing = [capsToEsc, .whisper]
        XCTAssertEqual(UserKeyMapping.removing(.whisper, from: existing), [capsToEsc])
    }

    /// Someone else mapping the mic key elsewhere is not ours to delete.
    func testRemovingLeavesDifferentMappingOfSameSourceKeyUntouched() {
        let dictationToF5 = KeyMapping(src: UserKeyMapping.dictationSrc, dst: 0x70000003E)
        XCTAssertEqual(UserKeyMapping.removing(.whisper, from: [dictationToF5]), [dictationToF5])
    }

    func testRemovingFromEmptyIsEmpty() {
        XCTAssertEqual(UserKeyMapping.removing(.whisper, from: []), [])
    }

    // MARK: - JSON payload

    /// Clearing writes an empty array, never null.
    func testJSONForNoMappingsIsEmptyArray() throws {
        XCTAssertEqual(try UserKeyMapping.json(for: []), #"{"UserKeyMapping":[]}"#)
    }

    /// Asserts decimal, not hex: the widely copied `0xC000000CF` form is not valid JSON
    /// and only works because hidutil's parser is lenient.
    func testJSONForWhisperMappingIsExactDecimalPayload() throws {
        XCTAssertEqual(
            try UserKeyMapping.json(for: [.whisper]),
            #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingDst":30064771176,"HIDKeyboardModifierMappingSrc":51539607759}]}"#
        )
    }

    func testJSONRoundTripsThroughParse() throws {
        let mappings = [capsToEsc, .whisper]
        let encoded = try UserKeyMapping.json(for: mappings)
        // hidutil echoes an OpenStep plist, but JSON is a valid input to our parser's
        // PropertyListSerialization path too, so this proves the pair agree on values.
        let data = encoded.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as! [String: [[String: Any]]]
        let rows = object["UserKeyMapping"]!
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][UserKeyMapping.srcKey] as? NSNumber, NSNumber(value: UserKeyMapping.dictationSrc))
        XCTAssertEqual(rows[1][UserKeyMapping.dstKey] as? NSNumber, NSNumber(value: UserKeyMapping.f13Dst))
    }

    // MARK: - Constants

    /// The mic key is consumer page 0x0C usage 0xCF, not kVK_F5 (96). Target is F13.
    func testUsageConstantsMatchHIDValues() {
        XCTAssertEqual(UserKeyMapping.dictationSrc, 0xC000000CF)
        XCTAssertEqual(UserKeyMapping.dictationSrc, 51539607759)
        XCTAssertEqual(UserKeyMapping.f13Dst, 0x700000068)
        XCTAssertEqual(UserKeyMapping.f13Dst, 30064771176)
        XCTAssertEqual(KeyMapping.whisper.src, UserKeyMapping.dictationSrc)
        XCTAssertEqual(KeyMapping.whisper.dst, UserKeyMapping.f13Dst)
    }
}
