# Whisper

A macOS menu bar app that records on demand, transcribes with Whisper, and pastes the result into the frontmost app. Transcription runs either locally through Python (`openai-whisper`) or through the OpenAI API.

## Requirements

- **macOS 15.5+** to run. On macOS 26 (Tahoe) the Settings window and transcript HUD render with Apple's Liquid Glass; earlier releases fall back to translucent materials automatically.
- **Xcode 26+** to build — the Liquid Glass APIs ship in the macOS 26 SDK, gated behind `#available(macOS 26.0, *)`.
- Microphone access, plus Accessibility access to paste into other apps. Both are requested from the first-run Setup checklist, which also reports engine readiness. Notifications are optional.
- Local mode needs Python 3.8+, the `openai-whisper` package, and `ffmpeg` on that Python's PATH. API mode needs an OpenAI key.

```bash
brew install ffmpeg
pip install -U openai-whisper
```

For a virtualenv or conda env, point the app at that env's python — e.g. `~/miniconda3/envs/whisper/bin/python`.

## Build

Open `Whisper.xcodeproj`, set your Team under Signing & Capabilities, then build and run. Launch at Login needs a codesigned build to take effect.

## Usage

Click the status bar icon or press the global hotkey (⌃A by default) to start recording, and again to stop and transcribe. Settings → General → Mic Key lets you use the mic key (F5) instead.

The transcript is pasted into the frontmost app, or left on the clipboard if pasting isn't possible. **Cancel Recording** discards a recording without transcribing it; **Cancel Transcription** stops one in flight. Starting and stopping without speaking is ignored silently.

Local transcription times out after ten minutes, API requests after two.

## Settings

**Engine** — local Python or the OpenAI API. The key is stored in the Keychain; the API model defaults to `gpt-4o-mini-transcribe`. Local models are `tiny`, `base`, `small`, `medium`, and `large`. Detect and Test verify the Python path.

**Language** — a fixed language, or auto-detect.

**Pasting** — press Enter after pasting (off by default), and preserve existing clipboard, which restores text, images, and files afterwards. Restoration is skipped if you copy something new first.

**General** — launch at login, the global hotkey, start/stop chimes (on by default, the same ones macOS Dictation uses), and the mic key.

**Mic key** — the mic key isn't F5 at the hardware level. It's HID consumer usage `0xCF`, which never reaches the event stream, so no hotkey API can intercept it. Whisper remaps it to F13 with `hidutil`, which is what stops the Dictation panel from opening. The remap lives only as long as Whisper runs and is removed when you disable it or quit, so nothing is left behind if you delete the app. Mappings owned by other tools are preserved.

## Troubleshooting

- **"Could not find a Python executable"** — set a valid path in Settings, or click Detect.
- **"No module named whisper"** — `pip install -U openai-whisper` into the Python you selected.
- **ffmpeg not found** — `brew install ffmpeg`, and make sure it's on the PATH for that Python.
- **Paste doesn't work** — grant Accessibility permission. The transcript stays on the clipboard either way.
- **Launch at Login doesn't stick** — codesigning is required; try a signed release build.

## Privacy

The microphone is live only while recording. API keys live in the Keychain rather than preferences, and keys saved by older builds are migrated automatically. Transcripts are never written to logs, and temporary recordings are deleted after success, failure, timeout, or cancellation. Enter is not pressed after pasting unless you enable it, so you can review before anything executes.

## Tests

```bash
xcodebuild test -project Whisper.xcodeproj -scheme Whisper -destination 'platform=macOS'
```

## License

None specified.
