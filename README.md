<div align="center">

# 🎙️ Whisper

### Record. Transcribe. Paste — anywhere.

A tiny macOS **menu-bar app** that turns your voice into text and drops it straight into whatever app you're using.

![macOS](https://img.shields.io/badge/macOS-15.5%2B-000000?style=flat-square&logo=apple&logoColor=white)
![Build](https://img.shields.io/badge/Build-Xcode%2026-147EFB?style=flat-square&logo=xcode&logoColor=white)
![Engine](https://img.shields.io/badge/Engine-Local%20or%20OpenAI-5B8DEF?style=flat-square)
![UI](https://img.shields.io/badge/UI-Liquid%20Glass-9AD0EC?style=flat-square)

</div>

---

## ✨ What it does

Press a key, talk, press it again. Whisper records your voice, transcribes it — **on-device** with `openai-whisper` or through the **OpenAI API** — and pastes the text into the frontmost app. That's the whole app.

<table>
<tr>
<td align="center" width="33%">🎤<br><b>1 · Record</b><br><sub>Hotkey, mic key, or a click</sub></td>
<td align="center" width="33%">✍️<br><b>2 · Transcribe</b><br><sub>Locally or via OpenAI</sub></td>
<td align="center" width="33%">📋<br><b>3 · Paste</b><br><sub>Into the app you're in</sub></td>
</tr>
</table>

> [!TIP]
> Nothing to say? Start and stop without speaking and Whisper silently ignores it — no empty paste, no error.

---

## 🚀 Quick start

```bash
# Only needed for local transcription — skip if you'll use the OpenAI API
brew install ffmpeg
pip install -U openai-whisper
```

1. Open `Whisper.xcodeproj`, set your **Team** under Signing & Capabilities, and run.
2. Work through the first-run **Setup** checklist — grant **Microphone** and **Accessibility**.
3. Press <kbd>⌃</kbd><kbd>A</kbd> (or the mic key) and start dictating.

> [!NOTE]
> Using a virtualenv or conda env? Point Whisper at that env's Python — e.g. `~/miniconda3/envs/whisper/bin/python`.

---

## 🎛️ The menu-bar item

Click the waveform to open the menu (**Start/Stop**, **Settings**, **Quit**). While transcribing, the icon gently **pulses**. And — depending on the mode you choose — one-press action buttons live right in the menu bar, so common actions never need the menu.

Pick the layout in **Settings › General › Menu-Bar Controls** with a live-preview slider:

<div align="center">

| Mode | Idle | While recording | Best for |
|:--|:--:|:--:|:--|
| **Icon Only** | `∿` | `∿🎙` | A clean menu bar — the menu does everything |
| **Cancel Button** <sub>· default</sub> | `∿` | `✕ · ∿🎙` | One-tap **cancel** without opening the menu |
| **Full Controls** | `∿ · ▶` | `✕ · ∿🎙 · ■` | **Start · stop · cancel**, all inline |

<sub>`∿` waveform (click → menu) &nbsp;·&nbsp; `🎙` recording &nbsp;·&nbsp; `✕` cancel &nbsp;·&nbsp; `▶` start &nbsp;·&nbsp; `■` stop & transcribe</sub>

</div>

The buttons fade and scale in and out, and the icon stays pinned to the menu bar's edge so it never jitters as things appear.

---

## ⚙️ Settings

### 🎧 Transcription

| Setting | Choices | Notes |
|:--|:--|:--|
| **Engine** | Local Whisper · OpenAI API | Flip between an on-device model and the cloud |
| **API Key** | — | Stored in the **Keychain**, never in preferences |
| **API Model** | any transcribe model | Default `gpt-4o-mini-transcribe` |
| **Local Model** | `tiny` · `base` · `small` · `medium` · `large` | Bigger = more accurate, slower. Default `base` |
| **Python** | Browse · Detect · Test | *Detect* finds a Python; *Test* verifies `whisper` is installed |
| **Language** | Auto-detect + 14 languages | English, Hebrew, Arabic, French, German, Spanish, Russian, Italian, Portuguese, Chinese, Japanese, Korean, Hindi, Turkish |
| **Last Transcript** | Copy to clipboard | A one-click copy of your most recent result |

> [!NOTE]
> Transcription times out after **10 minutes** locally, **2 minutes** for API requests.

### 📋 Pasting

| Setting | Default | What it does |
|:--|:--:|:--|
| **Press Enter after paste** | Off | Sends <kbd>↵</kbd> right after pasting |
| **Preserve existing clipboard** | On | Restores your prior clipboard (text, images, files) afterward |

> [!WARNING]
> **Press Enter after paste** will submit forms and run terminal commands the instant text lands. Off by default so you can review first.

### 🔧 General

| Setting | Details |
|:--|:--|
| **Launch at login** | Start Whisper when you sign in *(needs a codesigned build)* |
| **Start/stop chimes** | The same sounds macOS Dictation uses — on by default |
| **Menu-Bar Controls** | The [three layout modes](#-the-menu-bar-item) above |
| **Hotkey** | System-wide trigger — default <kbd>⌃</kbd><kbd>A</kbd>, rebindable |
| **Mic Key** | Use the mic key <kbd>F5</kbd> to toggle recording instead of opening Dictation |

### ✅ Setup

A first-run checklist that requests **Microphone** and **Accessibility** (and optional **Notifications**), and reports whether your chosen engine is ready to go. Revisit it any time from Settings.

<details>
<summary><b>🎙️ How the mic key remap works</b></summary>

<br>

The mic key isn't <kbd>F5</kbd> at the hardware level — it's HID consumer usage `0xCF`, which never reaches the event stream, so no hotkey API can intercept it. Whisper remaps it to <kbd>F13</kbd> with `hidutil`, which is what stops the Dictation panel from opening.

The remap lives **only while Whisper runs** and is removed when you disable it or quit — nothing is left behind if you delete the app, and mappings owned by other tools are preserved.

</details>

---

## 🔒 Privacy

- 🎤 The microphone is **live only while recording**.
- 🔑 API keys live in the **Keychain**, not preferences (keys from older builds are migrated automatically).
- 📝 Transcripts are **never written to logs**; temporary recordings are deleted after success, failure, timeout, or cancellation.
- ⏎ Enter is never pressed after pasting unless you opt in — so you can review before anything runs.

---

## 🧩 Requirements

| | |
|:--|:--|
| **Run** | macOS **15.5+** — on macOS 26 (Tahoe) the UI renders with Apple's **Liquid Glass**; earlier releases fall back to translucent materials |
| **Build** | **Xcode 26+** (Liquid Glass ships in the macOS 26 SDK) |
| **Permissions** | Microphone, plus Accessibility to paste into other apps |
| **Local engine** | Python 3.8+, the `openai-whisper` package, and `ffmpeg` on that Python's PATH |
| **API engine** | An OpenAI API key |

---

## 🛠️ Build & test

```bash
# Build & run
open Whisper.xcodeproj      # set your Team, then ⌘R

# Tests
xcodebuild test -project Whisper.xcodeproj -scheme Whisper -destination 'platform=macOS'
```

<details>
<summary><b>❓ Troubleshooting</b></summary>

<br>

| Symptom | Fix |
|:--|:--|
| *"Could not find a Python executable"* | Set a valid path in Settings, or click **Detect** |
| *"No module named whisper"* | `pip install -U openai-whisper` into the Python you selected |
| **ffmpeg not found** | `brew install ffmpeg`, and make sure it's on that Python's PATH |
| **Paste doesn't work** | Grant **Accessibility** — the transcript stays on the clipboard either way |
| **Launch at Login doesn't stick** | Codesigning is required; try a signed release build |

</details>

---

<div align="center">
<sub>License: none specified.</sub>
</div>
