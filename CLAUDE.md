# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Язык общения

**Всегда отвечай пользователю только на русском языке** — все объяснения, вопросы, отчёты о выполненной работе, сообщения коммитов и описания PR. Идентификаторы в коде и комментарии в коде — на английском, по обычным конвенциям Swift.

## Current state

A bare SwiftUI app skeleton exists (`GhostMeetApp.swift` + `ContentView.swift` — Xcode template, no GhostMeet logic yet). None of the spec is implemented: no audio capture, no STT, no LLM layer, no window/hotkey work. There is no test target yet.

```
GhostMeet/                      ← repo root
├── CLAUDE.md
├── docs/                       ← the authoritative spec (read before implementing)
└── GhostMeet/                  ← SRCROOT
    ├── GhostMeet.xcodeproj
    ├── Info.plist              ← lives HERE, outside the source folder — see below
    └── GhostMeet/              ← file-system-synchronized source group
```

Both spec documents are written in Russian. Keep docs and in-app user-facing strings consistent with that; code identifiers and comments follow normal Swift conventions in English.

## Build and run

All commands run from `GhostMeet/` (the folder containing `.xcodeproj`):

```bash
xcodebuild -project GhostMeet.xcodeproj -scheme GhostMeet -configuration Debug build
```

```bash
xcodebuild -project GhostMeet.xcodeproj -showBuildSettings -target GhostMeet
```

No test target exists yet, so there is no `test` command. When one is added, document how to run a single test here.

Verify what actually landed in the app bundle after touching Info.plist or deployment settings:

```bash
plutil -p ~/Library/Developer/Xcode/DerivedData/GhostMeet-*/Build/Products/Debug/GhostMeet.app/Contents/Info.plist
```

### Project configuration gotchas

- **Deployment target is macOS 14.4**, set at the *project* level (`MACOSX_DEPLOYMENT_TARGET`); the target inherits it, so the target's General tab shows the value without defining it. Do not raise it — Core Audio Process Tap requires 14.4.
- **App Sandbox is off** (`ENABLE_APP_SANDBOX = NO`). Deliberate: this is a local BYOK app that needs Process Tap and screen capture, not an App Store build.
- **All usage-description strings live in `SRCROOT/Info.plist`**, merged with the generated plist (`GENERATE_INFOPLIST_FILE` stays `YES`). Add new ones there, not as build settings — **`INFOPLIST_KEY_*` only works for keys Xcode knows**, and unknown ones like `NSAudioCaptureUsageDescription` / `NSScreenCaptureUsageDescription` are *silently dropped*: the build succeeds and the key simply never reaches the bundle. Always confirm with the `plutil` command above rather than trusting `-showBuildSettings`.
- **`Info.plist` must stay outside `GhostMeet/GhostMeet/`.** That folder is a `PBXFileSystemSynchronizedRootGroup` — anything inside is picked up automatically, and a plist there gets copied into `Contents/Resources/` as a stray duplicate. Same trap applies to any other non-source file.
- Because the source group is file-system-synchronized, **new `.swift` files are added to the target just by creating them on disk** — no pbxproj edit needed.

### Permissions and TCC

Four usage strings are declared: microphone (You channel), audio capture (Them channel via Process Tap), screen capture (Solve on screen), speech recognition (Apple Speech fallback). Note that macOS shows **no purpose string** for the Screen Recording prompt — `NSScreenCaptureUsageDescription` is declared for completeness, but the user will never read it.

The app is currently **ad-hoc signed** (`CODE_SIGN_IDENTITY = -`, no team). TCC grants are keyed to the signature, so the ad-hoc identity changes across rebuilds and macOS may re-prompt or silently drop previously granted mic/audio/screen permissions. If permissions start behaving erratically during audio work, this is the first thing to check — switching to a stable Apple Development identity (set `DEVELOPMENT_TEAM`) fixes it. Hardened Runtime is off; if it is ever enabled, microphone access will additionally require the `com.apple.security.device.audio-input` entitlement.

### Open decisions

- **Dock icon vs. accessory app.** A hidden always-on-top copilot would normally run as an accessory (`LSUIElement = true` / `NSApplication.setActivationPolicy(.accessory)`), with no Dock icon and no app switcher entry. Not set — decide when building the window layer, since it also affects how the window takes focus.

## What GhostMeet is

A macOS always-on-top overlay that assists during video calls (Meet, Telemost, Zoom, Teams). It listens to two audio channels, transcribes locally, and answers via pluggable LLMs — while staying invisible to screen sharing.

## Architecture invariants

These are the decisions that shape everything else; changing one has ripple effects across the codebase.

**Two channels never mix.** `You` (user mic, AVAudioEngine) and `Them` (call participants, **Core Audio Process Tap** on the meeting app's process) each get their own buffer, their own independent STT pass, and their own label in the transcript. The LLM always sees a speaker-labeled dialogue (`Them: …` / `You: …`) and infers from the system prompt whose side to answer for. Any change that risks the user's voice bleeding into `Them` breaks the core premise.

**Process Tap, not loopback.** Deliberately chosen over `getDisplayMedia` loopback (the approach cue uses): it captures only the selected process — no notifications or music — avoids loopback monitoring picking up the user's own voice, and needs only the narrower Audio Capture permission rather than Screen Recording. ScreenCaptureKit system audio is an optional fallback when Process Tap is unavailable.

**Local-first privacy.** STT is Whisper via MLX on-device (Apple Speech Framework as fallback); the LLM layer must support fully local providers (Ollama, LM Studio, llama.cpp server, MLX-LM) alongside cloud ones. BYOK, no backend server of our own — API keys live in Keychain only.

**Invisibility.** The window uses `NSWindow` level + `collectionBehavior` for always-on-top and `sharingType = .none` (content protection) so it is excluded from screen capture. This assumes the user shares a *tab or window*, not the whole display.

### Audio → answer pipeline

1. **Capture** — mic via AVAudioEngine; `Them` via Process Tap → Aggregate Device → IOProc
2. **Buffer + gate** — separate `you`/`them` PCM queues; flush every ~3–4 s with a minimum length (~0.5–0.8 s) and an RMS silence gate, so silence never triggers an STT call
3. **STT** — Whisper MLX per channel, independently
4. **Transcript** — append `Turn { channel, text, timestamp }`
5. **Context** — sliding window of the last ~10–15 turns; older turns are compressed by the background Summarizer and injected into the system prompt
6. **LLM** — one `LLMProvider` protocol behind an `LLMRouter`; cloud, local-HTTP, and CLI providers all conform to it. Streaming everywhere except the Summarizer.

The planned Swift file layout (`App/`, `UI/`, `Audio/`, `Speech/`, `Intelligence/{Context,LLM,Screen}/`, `Input/`, `Settings/`, `Utilities/`) is in [docs/GhostMeet.md](docs/GhostMeet.md) — follow it when creating files rather than inventing a new structure.

## Modes and prompts

Six user-facing modes — Assist, What should I say?, Follow-up, Recap, Ask, Solve on screen — plus a background Summarizer. **The authoritative prompt texts live in [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md); read it before touching prompt-building code, and update it in the same change if a prompt shifts.**

Cross-cutting rules from that file that are easy to get wrong:

- Never crash or bail on an empty transcript — substitute a placeholder like `(пусто)` and still answer
- Don't force Russian: response language follows the language of the Them/You turns or the user's question
- Different modes read different transcript window sizes (12 / 14 / 20 / all) and different max-token budgets (256–512 for Say/Follow-up, 2k–4k for Solve/Assist)
- Multimodal modes (Assist, Ask, Solve on screen) attach the screenshot to the *user* message; Solve additionally passes Vision-framework OCR text

## Permissions

`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSScreenCaptureUsageDescription` — exact Russian strings are in [docs/GhostMeet.md](docs/GhostMeet.md#разрешения-infoplist).

## Reference projects

The spec draws specific practices from open-source projects; consult them when implementing the corresponding layer: [cue](https://github.com/Blueturboguy07/cue) (dual-channel transcript, flush/RMS-gate constants, mode prompts, content protection), [CallCapture](https://github.com/bodharma/callcapture) / [Recap](https://github.com/RecapAI/Recap) / [AudioCap](https://github.com/insidegui/AudioCap) / [audiotee](https://github.com/makeusabrew/audiotee) (Process Tap), [Scripta](https://github.com/thehwang/Scripta) / [Muesli](https://github.com/Muesli-HQ/muesli) (local STT).
