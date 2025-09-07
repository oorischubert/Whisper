# Whisper (macOS)

A small macOS menu bar app that records audio on demand, transcribes it with Whisper, and pastes the transcript into the frontmost app. You can choose between running Whisper locally via Python (`openai-whisper`) or using the OpenAI API.

- Status bar menu: Start/Stop Recording, Preferences, Quit
- Global hotkey to toggle recording (default: Control+A)
- Pastes transcript automatically; can optionally press Enter and/or preserve the clipboard
- Shows the last transcript in Preferences for quick copy

## Requirements

- macOS: 13+ recommended. The project’s deployment target is configured for recent macOS (currently set to 15.5 in the project settings). You can lower it if needed.
- Xcode: 15+ recommended (project created with a recent Xcode version).
- Microphone permission (prompted on first use).
- Accessibility permission (System Settings → Privacy & Security → Accessibility) to paste into other apps.
- For Local Whisper mode:
  - Python 3.8+
  - `openai-whisper` Python package
  - `ffmpeg` available in the PATH used by that Python
- For API mode:
  - An OpenAI API key

Quick installs (Homebrew shown for macOS):

```bash
# Local mode deps
brew install ffmpeg
pip install -U openai-whisper

# If you prefer a virtualenv/conda, point the app to that env’s python
# e.g., ~/miniconda3/envs/whisper/bin/python
```

## Build & Run

1. Open `Whisper/Whisper.xcodeproj` in Xcode.
2. Select the `Whisper` target.
3. In Signing & Capabilities, set your Team and (optionally) change the bundle identifier.
4. Build and Run.

Notes:
- “Launch at Login” typically requires a codesigned build to take effect.
- If your machine isn’t on macOS 15 yet, consider lowering the target in the project build settings.

## Using the App

- Click the status bar icon or use the global hotkey (Control+A by default) to start/stop recording.
- When you stop, the app transcribes the audio:
  - Local mode: runs `python -m whisper` with your chosen model.
  - API mode: calls OpenAI’s transcription API and requests plain text.
- The text is pasted into the frontmost app. If pasting isn’t possible, the text is still copied so you can paste manually.

## Preferences

- Engine
  - Use OpenAI API: enable to use the API instead of local Python.
  - API Key: your `sk-…` key.
  - API Model: defaults to `whisper-1`.
  - Local Model: choose `tiny|base|small|medium|large`.
  - Python Executable: path to the Python that has `openai-whisper` installed; “Detect” and “Test” help verify.
- Language
  - Choose a fixed language or keep “Auto (detect)”.
- Pasting
  - Press Enter after paste (dangerous): off by default.
  - Preserve existing clipboard: restores your clipboard after pasting.
  - Debug toggles: bring Xcode front before pasting; show a popup with the transcript.
- General
  - Launch at login.
  - Hotkey: pick your global shortcut combination.
- Accessibility shortcut
  - A button opens System Settings to the Accessibility pane so you can grant permission.

## Troubleshooting

- “Could not find a Python executable”
  - Set a valid Python path in Preferences, or click Detect/Test.
- “No module named whisper”
  - Install `openai-whisper` in the Python you selected: `pip install -U openai-whisper`.
- ffmpeg not found
  - Install with `brew install ffmpeg` (or your platform’s package manager) and ensure it’s on PATH for the selected Python.
- API errors
  - Verify your API key and model name. The app requests `response_format=text`.
- Paste doesn’t work
  - Grant Accessibility permission. You can still copy the transcript and paste manually.
- Audio too short
  - Very short captures are ignored; speak briefly before stopping.
- Launch at Login doesn’t “stick” in debug
  - Codesigning is typically required. Try a signed release build.

## Project Structure (key files)

- `WhisperApp.swift` — App entry, exposes Preferences in Settings.
- `AppDelegate.swift` — Status item, hotkey handling, record/transcribe/paste flow, notifications.
- `Recorder.swift` — Records 16 kHz mono PCM WAV to a temp file.
- `Transcriber.swift` — Local (Python `openai-whisper`) and API transcription logic.
- `PasteboardManager.swift` — Clipboard/paste and optional Enter keypress (Accessibility).
- `PreferencesView.swift` — SwiftUI preferences UI.
- `GlobalShortcutMonitor.swift` — Modern system-wide key combination monitor.
- `HotKeyManager.swift` — Legacy F-key hotkey helper (not used by default).
- `HUDWindowController.swift` — Optional popup showing last transcript (debug).
- `LoadingAnimator.swift` — Status bar spinner while transcribing.

## Notes on Privacy & Safety

- Microphone is used only while recording is active.
- By default, the app pastes without pressing Enter so you can review before executing. Enable “Press Enter after paste” only if you fully trust the transcript.

## License

No license specified. If you plan to distribute or modify, consider adding a license.

