<div align="center">

# Whisper

**Record. Transcribe. Paste — anywhere.**

A tiny macOS **menu-bar app** that turns your voice into text and drops it straight into whatever app you're using.

![macOS](https://img.shields.io/badge/macOS-15.5+-1d1d1f?style=flat&logo=apple&logoColor=white)
![Build](https://img.shields.io/badge/Build-Xcode_26-1d1d1f?style=flat&logo=xcode&logoColor=white)
![Engine](https://img.shields.io/badge/Engine-Local_or_OpenAI-1d1d1f?style=flat)
![UI](https://img.shields.io/badge/UI-Liquid_Glass-1d1d1f?style=flat)

</div>

---

## What it does

Press a key, talk, press it again. Whisper records your voice, transcribes it — **on-device** with Whisper models running on Apple's Neural Engine, or through the **OpenAI API** — and pastes the text into the frontmost app. That's the whole app.

<table>
<tr>
<td align="center" width="33%"><b>1 · Record</b><br><sub>Hotkey, mic key, or a click</sub></td>
<td align="center" width="33%"><b>2 · Transcribe</b><br><sub>Locally or via OpenAI</sub></td>
<td align="center" width="33%"><b>3 · Paste</b><br><sub>Into the app you're in</sub></td>
</tr>
</table>

> [!TIP]
> Nothing to say? Start and stop without speaking and Whisper silently ignores it — no empty paste, no error.

> [!NOTE]
> The start chime plays once the mic is actually listening. Bluetooth headsets like AirPods take about a second to switch on their mic, so wait for the chime before you talk.

---

## Quick start

1. Open `Whisper.xcodeproj`, set your **Team** under Signing & Capabilities, and run.
2. Work through the first-run **Setup** checklist — grant **Microphone** and **Accessibility**, and click **Download** to fetch the on-device model.
3. Press <kbd>⌃</kbd><kbd>A</kbd> (or the mic key) and start dictating.

> [!NOTE]
> There's nothing else to install — no Python, no ffmpeg. Models download inside the app.

---

## The menu-bar item

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

## Settings

### Transcription

| Setting | Choices | Notes |
|:--|:--|:--|
| **Engine** | On This Mac · OpenAI API | Flip between an on-device model and the cloud |
| **API Key** | — | Stored in the **Keychain**, never in preferences |
| **API Model** | any transcribe model | Default `gpt-4o-mini-transcribe` |
| **Local Model** | Tiny · Base · Small · Large v3 Turbo · Large v3 | Pick one; if it isn't downloaded yet, Whisper offers to download it. Each row shows progress while downloading and a trash button to delete it. Default Base |
| **Language** | Auto-detect + 14 languages | English, Hebrew, Arabic, French, German, Spanish, Russian, Italian, Portuguese, Chinese, Japanese, Korean, Hindi, Turkish |
| **Last Transcript** | Copy to clipboard | A one-click copy of your most recent result |

> [!NOTE]
> Models are stored in `~/Library/Application Support/Whisper/Models` and run entirely offline once downloaded. The chosen model stays loaded while you're dictating and is freed after 15 idle minutes; the next dictation reloads it in a second or two.
> Transcription times out after **10 minutes** locally, **2 minutes** for API requests.

### Pasting

| Setting | Default | What it does |
|:--|:--:|:--|
| **Press Enter after paste** | Off | Sends <kbd>↵</kbd> right after pasting |
| **Preserve existing clipboard** | On | Restores your prior clipboard (text, images, files) afterward |

> [!WARNING]
> **Press Enter after paste** will submit forms and run terminal commands the instant text lands. Off by default so you can review first.

### General

| Setting | Details |
|:--|:--|
| **Launch at login** | Start Whisper when you sign in *(needs a codesigned build)* |
| **Start/stop chimes** | The same sounds macOS Dictation uses — on by default |
| **Menu-Bar Controls** | The [three layout modes](#the-menu-bar-item) above |
| **Hotkey** | System-wide trigger — default <kbd>⌃</kbd><kbd>A</kbd>, rebindable |
| **Mic Key** | Use the mic key <kbd>F5</kbd> to toggle recording instead of opening Dictation |

### Setup

A first-run checklist that requests **Microphone** and **Accessibility** (and optional **Notifications**), and reports whether your chosen engine is ready to go. Revisit it any time from Settings.

<details>
<summary><b>How the mic key remap works</b></summary>

<br>

The mic key isn't <kbd>F5</kbd> at the hardware level — it's HID consumer usage `0xCF`, which never reaches the event stream, so no hotkey API can intercept it. Whisper remaps it to <kbd>F13</kbd> with `hidutil`, which is what stops the Dictation panel from opening.

The remap lives **only while Whisper runs** and is removed when you disable it or quit — nothing is left behind if you delete the app, and mappings owned by other tools are preserved.

</details>

---

## Privacy

- The microphone is **live only while recording**.
- API keys live in the **Keychain**, not preferences (keys from older builds are migrated automatically).
- Transcripts are **never written to logs**; temporary recordings are deleted after success, failure, timeout, or cancellation.
- Enter is never pressed after pasting unless you opt in — so you can review before anything runs.

---

## Requirements

| | |
|:--|:--|
| **Run** | macOS **15.5+** — on macOS 26 (Tahoe) the UI renders with Apple's **Liquid Glass**; earlier releases fall back to translucent materials |
| **Build** | **Xcode 26+** (Liquid Glass ships in the macOS 26 SDK) |
| **Permissions** | Microphone, plus Accessibility to paste into other apps |
| **Local engine** | Nothing extra — built in via [WhisperKit](https://github.com/argmaxinc/WhisperKit). Apple silicon recommended |
| **API engine** | An OpenAI API key |

---

## Build & test

```bash
# Build & run
open Whisper.xcodeproj      # set your Team, then ⌘R

# Tests
xcodebuild test -project Whisper.xcodeproj -scheme Whisper -destination 'platform=macOS'
```

<details>
<summary><b>Troubleshooting</b></summary>

<br>

| Symptom | Fix |
|:--|:--|
| *"The … model isn't downloaded yet"* | Open **Settings › Transcription** and download it, or pick one that's downloaded |
| **Model download failed** | Check your internet connection and click **Retry** |
| **Paste doesn't work** | Grant **Accessibility** — the transcript stays on the clipboard either way |
| **Launch at Login doesn't stick** | Codesigning is required; try a signed release build |

</details>

---

<div align="center">
<sub>License: none specified.</sub>
</div>
