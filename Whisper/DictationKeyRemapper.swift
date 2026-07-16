import Foundation

/// One `hidutil` UserKeyMapping entry.
struct KeyMapping: Hashable {
    let src: UInt64
    let dst: UInt64

    /// The mapping Whisper owns: mic key → F13.
    static let whisper = KeyMapping(src: UserKeyMapping.dictationSrc, dst: UserKeyMapping.f13Dst)
}

/// Pure model of the `UserKeyMapping` property that `hidutil` reads and writes.
/// Free of `Process` so every rule here is unit-testable.
enum UserKeyMapping {
    /// Consumer page 0x0C, usage 0xCF "Voice Command" — the mic key on Apple keyboards.
    /// It never reaches the CGEvent layer (there is no NX_KEYTYPE for it), so no event
    /// tap or hotkey API can see it. Remapping at the HID layer is the only way to stop
    /// macOS Dictation from claiming the key.
    static let dictationSrc: UInt64 = 0xC000000CF
    /// Keyboard page 0x07, usage 0x68 = F13 (kVK_F13). F13 has no default macOS binding
    /// and no physical key on laptop or Magic keyboards.
    static let f13Dst: UInt64 = 0x700000068

    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    enum ParseError: Error {
        case unrecognized(String)
    }

    /// Parses `hidutil property --get UserKeyMapping` stdout, which is an OpenStep
    /// plist rather than JSON. Empty forms are `(null)` (never set) and `()` (cleared).
    ///
    /// Throws instead of returning `[]` on unrecognized input: callers merge onto this
    /// result and write it straight back, so a silent `[]` would erase mappings that
    /// belong to other tools.
    static func parse(_ output: String) throws -> [KeyMapping] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(null)" else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let rows = plist as? [[String: Any]] else {
            throw ParseError.unrecognized(trimmed)
        }

        return try rows.map { row in
            // Every value arrives as a String: OpenStep plists have no number type.
            guard let src = number(row[srcKey]), let dst = number(row[dstKey]) else {
                throw ParseError.unrecognized(trimmed)
            }
            return KeyMapping(src: src, dst: dst)
        }
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        guard let s = value as? String else { return nil }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return UInt64(s.dropFirst(2), radix: 16) }
        return UInt64(s)
    }

    /// Adds `new`, replacing any existing mapping of the same source key and preserving
    /// every other tool's entries in order. Idempotent.
    static func merged(_ existing: [KeyMapping], adding new: KeyMapping) -> [KeyMapping] {
        existing.filter { $0.src != new.src } + [new]
    }

    /// Removes only an exact src+dst match, so a different mapping of the same source
    /// key — one we did not create — survives.
    static func removing(_ target: KeyMapping, from existing: [KeyMapping]) -> [KeyMapping] {
        existing.filter { $0 != target }
    }

    /// Builds the `--set` payload. Values must be decimal integers: the widely copied
    /// `0xC000000CF` form is not valid JSON and only works because hidutil's parser is
    /// lenient. `.sortedKeys` keeps the output deterministic for tests.
    static func json(for mappings: [KeyMapping]) throws -> String {
        let rows = mappings.map {
            [srcKey: NSNumber(value: $0.src), dstKey: NSNumber(value: $0.dst)]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["UserKeyMapping": rows],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

enum RemapError: LocalizedError {
    case hidutilFailed(Int32, String)
    case blocked

    var errorDescription: String? {
        switch self {
        case .blocked:
            return "macOS blocked the key remap. Your organization's device management may prevent keyboard remapping."
        case .hidutilFailed(let code, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "hidutil failed (exit \(code))." : "hidutil failed: \(detail)"
        }
    }
}

/// Applies and removes the mic-key → F13 remap, and tracks whether it is live.
///
/// The mapping's lifetime is tied to this process: applied on launch when enabled,
/// removed on quit. That keeps the invariant "mic key works exactly when Whisper is
/// running" and leaves nothing behind if the app is deleted.
@MainActor
final class DictationKeyRemapper: ObservableObject {
    static let shared = DictationKeyRemapper()

    enum Status: Equatable {
        case inactive
        case active
        case failed(String)
    }

    @Published private(set) var status: Status = .inactive
    /// While true, a mic-key press reports itself instead of toggling a recording.
    @Published var isTesting = false
    @Published private(set) var lastKeyPressAt: Date?

    private init() {}

    func noteTestPress() {
        lastKeyPressAt = Date()
        isTesting = false
    }

    /// The remap took but binding the key did not, e.g. another app owns F13.
    func noteFailure(_ message: String) {
        status = .failed(message)
    }

    func apply() async {
        do {
            try await Task.detached { try Self.applySync() }.value
            status = .active
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func remove() async {
        await Task.detached { Self.removeSync() }.value
        status = .inactive
    }

    // MARK: - hidutil

    nonisolated static func applySync() throws {
        let existing = try currentMappings()
        try setMappings(UserKeyMapping.merged(existing, adding: .whisper))

        // `hidutil --get` exits 0 even for a bogus property name, so exit status proves
        // nothing. Only reading the mapping back proves it took — and this is what
        // detects an MDM-blocked machine.
        guard try currentMappings().contains(.whisper) else {
            throw RemapError.blocked
        }
    }

    /// Best-effort and never throws: also called from `applicationWillTerminate`.
    nonisolated static func removeSync() {
        guard let existing = try? currentMappings() else { return }
        let updated = UserKeyMapping.removing(.whisper, from: existing)
        guard updated.count != existing.count else { return }
        try? setMappings(updated)
    }

    nonisolated private static func currentMappings() throws -> [KeyMapping] {
        try UserKeyMapping.parse(runHidutil(["property", "--get", "UserKeyMapping"]))
    }

    nonisolated private static func setMappings(_ mappings: [KeyMapping]) throws {
        // Removal writes {"UserKeyMapping":[]}, never null.
        _ = try runHidutil(["property", "--set", UserKeyMapping.json(for: mappings)])
    }

    @discardableResult
    nonisolated private static func runHidutil(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        // No `--matching`: it only matches UsagePage 1 / Usage 6, which excludes the
        // consumer-page service that emits the mic key.
        // The JSON is one raw argument here — it must not carry the shell's quotes.
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // Read to EOF before waiting, so a full pipe buffer can never deadlock us.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw RemapError.hidutilFailed(process.terminationStatus, output)
        }
        return output
    }
}
