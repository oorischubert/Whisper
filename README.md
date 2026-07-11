# Whisper (macOS)

A small macOS menu bar app that records audio on demand, transcribes it with Whisper, and pastes the transcript into the frontmost app. You can choose between running Whisper locally via Python (`openai-whisper`) or using the OpenAI API.

- Status bar menu: Start/Stop Recording, transcription status/cancellation, Settings, Quit
- Global hotkey to toggle recording (default: Control+A)
- Pastes transcript automatically, with permission-aware copy fallback
- Can preserve rich clipboard content and optionally press Enter after pasting
- Shows the last transcript in Preferences for quick copy

## Requirements

- macOS: 13+ recommended. The project’s deployment target is configured for recent macOS (currently set to 15.5 in the project settings). You can lower it if needed.
- Xcode: 15+ recommended (project created with a recent Xcode version).
- Microphone permission (requested from the first-run Setup checklist).
- Accessibility permission (System Settings → Privacy & Security → Accessibility) to paste into other apps.
- Notifications are optional; the menu-bar status works without them.
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

1. Open `Whisper.xcodeproj` in Xcode.
2. Select the `Whisper` target.
3. In Signing & Capabilities, set your Team and (optionally) change the bundle identifier.
4. Build and Run.

Notes:
- “Launch at Login” typically requires a codesigned build to take effect.
- If your machine isn’t on macOS 15 yet, consider lowering the target in the project build settings.

## Using the App

- On first launch, complete the Setup checklist. It reports microphone, Accessibility, notifications, and transcription-engine readiness without prompting for permissions unexpectedly.
- Click the status bar icon or use the global hotkey (Control+A by default) to start/stop recording.
- When you stop, the app transcribes the audio:
  - Local mode: runs `python -m whisper` with your chosen model.
  - API mode: calls OpenAI’s transcription API and requests plain text.
- The text is pasted into the frontmost app. If pasting isn’t possible, the text is still copied so you can paste manually.
- While transcription is running, choose **Cancel Transcription** from the status menu to stop it.
- Local transcription times out after ten minutes; API requests time out after two minutes.

## Preferences

- Engine
  - Use OpenAI API: enable to use the API instead of local Python.
  - API Key: your `sk-…` key, stored in macOS Keychain.
  - API Model: defaults to `whisper-1`.
  - Local Model: choose `tiny|base|small|medium|large`.
  - Python Executable: path to the Python that has `openai-whisper` installed; “Detect” and “Test” help verify.
- Language
  - Choose a fixed language or keep “Auto (detect)”.
- Pasting
  - Press Enter after paste (dangerous): off by default.
  - Preserve existing clipboard: restores text, images, files, and other pasteboard formats after pasting.
  - Clipboard restoration is skipped if you copy something new before the restore occurs.
  - Debug toggles: bring Xcode front before pasting; show a popup with the transcript.
- General
  - Launch at login.
  - Hotkey: pick your global shortcut combination.
- Setup
  - The Setup checklist shows microphone, Accessibility, notification, and engine readiness.
  - Permissions are requested only when you choose the corresponding setup action.

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
  - Grant Accessibility permission from the Setup checklist. If permission is unavailable, the transcript remains copied for manual pasting.
- Audio too short
  - Very short captures are ignored; speak briefly before stopping. The app returns to its ready state automatically.
- Launch at Login doesn’t “stick” in debug
  - Codesigning is typically required. Try a signed release build.

## Project Structure (key files)

- `WhisperApp.swift` — App entry, exposes Preferences in Settings.
- `AppDelegate.swift` — Status item, hotkey handling, record/transcribe/paste flow, cancellation, and notifications.
- `AppActivity.swift` — Explicit idle, recording, and transcribing states.
- `AppSettings.swift` — Persisted preferences and first-run setup state.
- `KeychainStore.swift` — Secure OpenAI API-key persistence and migration.
- `Recorder.swift` — Records 16 kHz mono PCM WAV to a temp file.
- `Transcriber.swift` — Cancellable local/API transcription, timeouts, diagnostics, and temporary-file cleanup.
- `PasteboardManager.swift` — Rich clipboard preservation, permission-aware paste, and optional Enter keypress.
- `PreferencesView.swift` — SwiftUI setup checklist and preferences UI.
- `GlobalShortcutMonitor.swift` — Modern system-wide key combination monitor.
- `HotKeyManager.swift` — Legacy F-key hotkey helper (not used by default).
- `HUDWindowController.swift` — Optional popup showing last transcript (debug).
- `LoadingAnimator.swift` — Status bar spinner while transcribing.
- `WhisperTests/CoreBehaviorTests.swift` — State, multipart-form, and clipboard regression tests.

## Notes on Privacy & Safety

- Microphone is used only while recording is active.
- API credentials are stored in macOS Keychain rather than preferences.
- Existing API keys saved by older builds are migrated to Keychain automatically.
- Transcript contents are not written to application logs.
- Temporary recordings and local-transcription output are removed after success, failure, timeout, or cancellation.
- By default, the app pastes without pressing Enter so you can review before executing. Enable “Press Enter after paste” only if you fully trust the transcript.

## Tests

Run the macOS unit tests from Xcode or with:

```bash
xcodebuild test -project Whisper.xcodeproj -scheme Whisper -destination 'platform=macOS'
```

## License

No license specified. If you plan to distribute or modify, consider adding a license.
