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

## What GhostMeet is

A macOS always-on-top overlay that assists during video calls (Meet, Telemost, Zoom, Teams). It listens to two audio channels, transcribes locally, and answers via pluggable LLMs — while staying invisible to screen sharing.

**The MVP targets one scenario: a technical interview where the user is the candidate.** That is the tightest requirement set — latency is critical, `Solve on screen` is the primary mode rather than a bonus, and reaching for a hotkey on camera is conspicuous. Other scenarios are relaxations of it and are not designed for separately.

## Where decisions live

Design decisions from the grilling session are recorded, not just implied by the code — read them before reopening a settled question:

- [CONTEXT.md](CONTEXT.md) — the glossary. `You`, `Them`, `Реплика`, `Подсказка`, `Профиль` have precise definitions; use those words and don't drift to synonyms.
- [docs/adr/](docs/adr/) — [0001](docs/adr/0001-swappable-backends-behind-protocols.md) swappable backends, [0002](docs/adr/0002-stt-engine-choice.md) STT engine choice, [0003](docs/adr/0003-proactive-suggestion-loop.md) the proactive suggestion loop, [0004](docs/adr/0004-invisibility-scope.md) the limits of invisibility.

The spec in `docs/` has been reconciled with these; where an older reference project (cue) disagrees, the ADRs win.

## Architecture invariants

These are the decisions that shape everything else; changing one has ripple effects across the codebase.

**Two channels never mix.** `You` (user mic, AVAudioEngine **with VPIO enabled**) and `Them` (call participants, captured from the source app) each get their own buffer, their own independent STT pass, and their own label in the transcript. Channel membership is decided by *source*, never by meaning: everything from the mic is `You` even when the user reads someone else's question aloud. VPIO (`setVoiceProcessingEnabled`) is what stops the other party's voice leaking from the speakers into `You` — without it the transcript quietly corrupts and the LLM starts answering the wrong side.

**Two implementations per external seam.** Capture, STT and LLM each have two or more backends behind one protocol, selectable in settings — see [ADR-0001](docs/adr/0001-swappable-backends-behind-protocols.md). Branching must not leak upward: `Speech` doesn't know where the audio came from, `Intelligence` doesn't know what transcribed it. Backends are built **one at a time** through the seam, not in parallel.

**Process Tap is the default, not the only way.** Core Audio Process Tap ships first and stays the default (no video pipeline, keeps working if Screen Recording is revoked); ScreenCaptureKit is the second backend and the automatic fallback. Note the spec's original justification is partly obsolete: both APIs are **app-level**, neither isolates a browser tab, and Screen Recording is needed anyway because every suggestion carries a screenshot.

**Local-first privacy.** STT is on-device (see [ADR-0002](docs/adr/0002-stt-engine-choice.md) — **WhisperKit, not MLX**); the LLM layer must support fully local providers (Ollama, LM Studio, llama.cpp server, MLX-LM) alongside cloud ones. BYOK, no backend server of our own — API keys live in Keychain only. Nothing is written to disk unless the user turns it on.

**Invisibility.** The window uses `NSWindow` level + `collectionBehavior` for always-on-top and `sharingType = .none` (content protection) so it is excluded from screen capture — including from our own screenshots, which is what keeps the model from seeing its previous answer. The app runs as an accessory (`LSUIElement`), and whole-display sharing is explicitly out of scope ([ADR-0004](docs/adr/0004-invisibility-scope.md)). Failures are surfaced **inside the window only** — a system notification banner would appear over the shared screen and give the app away.

### Audio → answer pipeline

1. **Capture** — mic via AVAudioEngine + VPIO; `Them` via Process Tap → Aggregate Device → IOProc (or SCK)
2. **Buffer + gate** — separate `you`/`them` PCM queues; a turn closes after ~800 ms of silence, with a minimum length (~0.5–0.8 s), an RMS silence gate, and a ~10 s forced flush for pause-less monologues. The fixed 3–4 s flush cue uses is deliberately **not** used — half the window would be pure added latency
3. **STT** — WhisperKit per channel, independently
4. **Transcript** — append `Turn { channel, text, timestamp }`
5. **Context** — sliding window of the last ~10–15 turns; older turns are compressed by the background Summarizer and injected into the system prompt, along with the user's `Профиль` (experience, stack, role)
6. **LLM** — one `LLMProvider` protocol behind an `LLMRouter`; cloud, local-HTTP, and CLI providers all conform to it. Streaming everywhere except the Summarizer.

**The loop is proactive** ([ADR-0003](docs/adr/0003-proactive-suggestion-loop.md)): closing a `Them` turn fires steps 3–6 automatically, with a screenshot attached to *every* request. A new `Them` turn cancels the in-flight generation and restarts; `You` speech cancels nothing — the suggestion stays on screen as a crib until `Them` speaks again. Hotkeys are a secondary path, not the main one.

The planned Swift file layout (`App/`, `UI/`, `Audio/`, `Speech/`, `Intelligence/{Context,LLM,Screen}/`, `Input/`, `Settings/`, `Utilities/`) is in [docs/GhostMeet.md](docs/GhostMeet.md) — follow it when creating files rather than inventing a new structure.

## Modes and prompts

Six user-facing modes — Assist, What should I say?, Follow-up, Recap, Ask, Solve on screen — plus a background Summarizer. **The authoritative prompt texts live in [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md); read it before touching prompt-building code, and update it in the same change if a prompt shifts.**

Cross-cutting rules from that file that are easy to get wrong:

- Never crash or bail on an empty transcript — substitute a placeholder like `(пусто)` and still answer
- Don't force Russian: response language follows the language of the Them/You turns or the user's question
- Different modes read different transcript window sizes (12 / 14 / 20 / all) and different max-token budgets (256–512 for Say/Follow-up, 2k–4k for Solve/Assist)
- Multimodal modes (Assist, Ask, Solve on screen) attach the screenshot to the *user* message; Solve additionally passes Vision-framework OCR text
- The optional `resume_context` block at the end of that file is **not optional here** — it carries the user's `Профиль` and ships in the MVP. Without it the model suggests experience the user doesn't have, which is a worse failure than a slow answer

## Permissions

Declared in [GhostMeet/Info.plist](GhostMeet/Info.plist), not in the spec — the spec lists three, the project also declares `NSSpeechRecognitionUsageDescription` for the Apple Speech fallback. See the TCC notes above before debugging permission behaviour.

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature-slug>/` — this repo has no git remote. See [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

The five canonical roles, unrenamed (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a `Status:` line in each issue file. See [docs/agents/triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Single-context: one `CONTEXT.md` and one `docs/adr/` at the repo root, both created lazily by `/domain-modeling`. See [docs/agents/domain.md](docs/agents/domain.md).

## Reference projects

The spec draws specific practices from open-source projects; consult them when implementing the corresponding layer: [cue](https://github.com/Blueturboguy07/cue) (dual-channel transcript, flush/RMS-gate constants, mode prompts, content protection), [CallCapture](https://github.com/bodharma/callcapture) / [Recap](https://github.com/RecapAI/Recap) / [AudioCap](https://github.com/insidegui/AudioCap) / [audiotee](https://github.com/makeusabrew/audiotee) (Process Tap), [Scripta](https://github.com/thehwang/Scripta) / [Muesli](https://github.com/Muesli-HQ/muesli) (local STT).
