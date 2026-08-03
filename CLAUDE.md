# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Язык общения

**Всегда отвечай пользователю только на русском языке** — все объяснения, вопросы, отчёты о выполненной работе, сообщения коммитов и описания PR. Идентификаторы в коде и комментарии в коде — на английском, по обычным конвенциям Swift.

## Current state

This repository contains **only a specification — no source code, no Xcode project, no build system, and no git repo yet.** The entire contents are:

- [docs/GhostMeet.md](docs/GhostMeet.md) — the working spec (architecture, tech stack, planned file layout, MVP/v1 checklists)
- [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md) — full system/user prompt texts for every LLM mode

There are no build, lint, or test commands to run. The first implementation task is to create the macOS app target itself (SwiftUI + AppKit, min deployment **macOS 14.4** — required for Core Audio Process Tap). Do not invent or reference build commands that don't exist; add them to this file once a real project/scheme exists.

Both spec documents are written in Russian. Keep docs and in-app user-facing strings consistent with that; code identifiers and comments follow normal Swift conventions in English.

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
