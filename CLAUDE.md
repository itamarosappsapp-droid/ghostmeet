# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Язык общения

**Всегда отвечай пользователю только на русском языке** — все объяснения, вопросы, отчёты о выполненной работе, сообщения коммитов и описания PR. Идентификаторы в коде и комментарии в коде — на английском, по обычным конвенциям Swift.

## Current state

The MVP pipeline runs end to end: both channels are captured, turns are cut on pauses, speech is recognised locally, a closed `Them` turn starts a suggestion on its own, and the user can ask for one themselves. **360 tests** across 53 suites (Swift Testing, target `GhostMeetTests`).

Done: project skeleton and test target, microphone capture with VPIO, turn segmentation, WhisperKit recognition with model selection, the overlay window, the `Them` channel (both backends, SCK by default), settings with per-provider keys, the proactive `Assist` loop with a streaming Claude provider, the full provider router (OpenAI-compatible family, Gemini, CLI tools), screenshot and OCR on every request, the suggestion lifecycle (a newer `Them` turn supersedes the answer in flight), the manual `Ask` / `Solve on screen` modes under those same cancellation rules, global hotkeys and per-channel indicators.

Every ticket of the interview MVP is implemented; several are `ready-for-human` and awaiting review. Tickets live in `.scratch/interview-mvp/`. What is left beyond them is the v1.0 list in [docs/GhostMeet.md](docs/GhostMeet.md) — the background Summarizer above all, which is why the `{{#if summary}}` block of every prompt is still unbuilt.

The audio investigation is over and its scaffolding is gone: no diagnostics object, no level probes, no environment flags of our own. What survived it are the fixes it found — `MicCaptureService.firstChannel`, `ProcessTap.DeliveryFormat`, `PCMMixdown`, the mic tap installed with `format: nil` — and their regression tests. Logging is lifecycle-only now: capture start and failure (`SessionEngine`), `Them` channel status (`SessionController`), recognition model phase (`SpeechModelStatus`). Nothing per frame, nothing anybody said. Keep it that way — a per-frame log in this app writes the conversation to disk.

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

Run the whole suite (Swift Testing, target `GhostMeetTests`):

```bash
xcodebuild -project GhostMeet.xcodeproj -scheme GhostMeet -destination 'platform=macOS' test
```

Run a single test — `-only-testing:` takes `Target/Suite/testFunction`:

```bash
xcodebuild -project GhostMeet.xcodeproj -scheme GhostMeet -destination 'platform=macOS' test -only-testing:GhostMeetTests/SkeletonTests/testBundleIsWired
```

The scheme is **shared** (`xcshareddata/xcschemes/GhostMeet.xcscheme`) and committed — it lists the test target under both the build and test actions. Don't rely on Xcode's auto-created scheme; it lives in `xcuserdata`, which is gitignored.

When several builds run at once (parallel agents), give each its own `-derivedDataPath` — concurrent builds sharing the default DerivedData corrupt each other.

Verify what actually landed in the app bundle after touching Info.plist or deployment settings:

```bash
plutil -p ~/Library/Developer/Xcode/DerivedData/GhostMeet-*/Build/Products/Debug/GhostMeet.app/Contents/Info.plist
```

### Project configuration gotchas

- **Deployment target is macOS 14.4**, set at the *project* level (`MACOSX_DEPLOYMENT_TARGET`); the target inherits it, so the target's General tab shows the value without defining it. Do not raise it — Core Audio Process Tap requires 14.4.
- **App Sandbox is off** (`ENABLE_APP_SANDBOX = NO`). Deliberate: this is a local BYOK app that needs Process Tap and screen capture, not an App Store build.
- **All usage-description strings live in `SRCROOT/Info.plist`**, merged with the generated plist (`GENERATE_INFOPLIST_FILE` stays `YES`). Add new ones there, not as build settings — **`INFOPLIST_KEY_*` only works for keys Xcode knows**, and unknown ones like `NSAudioCaptureUsageDescription` / `NSScreenCaptureUsageDescription` are *silently dropped*: the build succeeds and the key simply never reaches the bundle. Always confirm with the `plutil` command above rather than trusting `-showBuildSettings`.
- **`Info.plist` must stay outside `GhostMeet/GhostMeet/`.** That folder is a `PBXFileSystemSynchronizedRootGroup` — anything inside is picked up automatically, and a plist there gets copied into `Contents/Resources/` as a stray duplicate. Same trap applies to any other non-source file.
- Because the source group is file-system-synchronized, **new `.swift` files are added to the target just by creating them on disk** — no pbxproj edit needed. Adding an SPM dependency, a target, or a scheme still means editing `project.pbxproj` by hand.
- **Give every concurrent build its own `-derivedDataPath`.** Parallel agents sharing the default DerivedData corrupt each other's builds.
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on, so `CGRect` / `CGSize` need an explicit `import CoreGraphics` even where `Foundation` is already imported. A standalone `swiftc -typecheck` without the flag will not reproduce the error.

### Silent audio failures

Two independent bugs in this project produced *identical* symptoms — capture running, indicators lit, buffers arriving at the right rate, every sample zero, not one error code anywhere. Both came from the same root: **macOS reports one audio format and delivers another**, and the mismatch is never an error, only silence.

- **Microphone.** With VPIO on, the built-in mic presents **seven** channels — processed mono plus the raw mic-array elements. `AVAudioConverter` has no channel map for folding seven into one, so it returns silence without complaining. Take channel 0 (the processed one) yourself; never ask a converter to downmix >2 channels.
- **Process Tap.** The tap *reports* interleaved stereo and *delivers* two separate channel buffers. `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` returns nil on a layout mismatch — silently — so every frame vanishes while the IOProc runs perfectly. Derive the format from `AudioBufferList.mNumberBuffers`, not from what the tap claims.

The lesson generalises: **in this codebase, never trust a reported audio format — measure what actually arrived.** When audio "doesn't work", the first move is to log frame counts, RMS and buffer layout; return codes will tell you nothing. `MicChannelExtractionTests` guards the first case.

VPIO also **ducks all other system audio** while capturing, which both annoys the user and quietens the very audio `Them` is trying to recognise. Set `voiceProcessingOtherAudioDuckingConfiguration` to `.min`.

### Permissions and TCC

Four usage strings are declared: microphone (You channel), audio capture (Them channel via Process Tap), screen capture (Solve on screen), speech recognition (Apple Speech fallback). Note that macOS shows **no purpose string** for the Screen Recording prompt — `NSScreenCaptureUsageDescription` is declared for completeness, but the user will never read it.

The app is signed with a **stable Apple Development identity** (personal team). This matters more than it looks: TCC grants are keyed to the signature, and while the project was ad-hoc signed every rebuild produced a new identity — macOS then re-prompted, or worse, reported the microphone as authorised and handed the app pure silence. If permissions start behaving oddly, check the signature first. Hardened Runtime is off; if it is ever enabled, microphone access will additionally require the `com.apple.security.device.audio-input` entitlement.

## Обязательные правила работы

Два правила, нарушение которых считается незакрытой работой, а не мелочью. Оба появились из реальных ошибок в этом проекте.

### 1. Документы правятся тем же изменением, что и код

**После каждой доработки — до того, как назвать её законченной — пройди по документам и приведи их в соответствие.** Не «когда-нибудь потом»: расходящиеся документ и код хуже отсутствующего документа, потому что им верят.

Что проверять каждый раз:

- `docs/GhostMeet.md` — спека продукта: возможности, стек, структура файлов, списки MVP/v1. **Структура файлов в ней — инструкция для агентов**, и если она врёт, следующий агент создаст файлы с несуществующими именами.
- `docs/GhostMeet-Prompts.md` — авторитетные тексты промптов. Промпт в коде и промпт здесь обязаны совпадать дословно; правятся одним изменением.
- `CONTEXT.md` — глоссарий. Новое понятие в коде без термина в глоссарии — источник будущего расползания синонимов.
- `CLAUDE.md` — этот файл: состояние проекта, грабли, инварианты.
- `.scratch/interview-mvp/` — тикеты и спека: статусы, критерии, комментарии о найденном.
- **Ссылки между документами.** Относительные пути легко ломаются; из `.scratch/interview-mvp/issues/` до корня три уровня, а не два. Проверяй, что каждая ссылка ведёт в существующий файл.

Отдельно: если по ходу работы выяснился факт, который стоил времени — неочевидное поведение системы, ловушка API, причина молчаливого отказа, — он идёт в документы. Час отладки, не оставивший следа в тексте, будет потрачен снова.

### 2. ADR никогда не переписывается — выпускается новый

**Решение, однажды записанное, не редактируется и не удаляется.** Чтобы изменить его, напиши **новый** ADR со следующим номером, который явно говорит, какой ADR он заменяет, и добавь в старый одну строку `status:` со ссылкой на заменяющий. Эта строка и короткая врезка-предупреждение — единственные допустимые правки заменённого ADR.

Причина: ценность ADR не в том, что он описывает текущее положение дел, а в том, что он фиксирует **что было решено и на каком основании**. Переписав его, теряешь именно это — читатель больше не видит ни отменённого решения, ни причин, по которым оно казалось верным. В этом проекте так уже терялся ADR-0005, восстановленный потом по памяти.

Что можно без нового ADR: дописать наблюдение, которое **не меняет решения** (например, «проверено вживую, держится»). Что нельзя: менять сам вывод, условия, при которых он верен, или его последствия — это новый ADR.

Заменённый ADR остаётся в каталоге навсегда. Пример пары: [ADR-0005](docs/adr/0005-vpio-and-process-tap-cannot-coexist.md) и заменяющий его [ADR-0007](docs/adr/0007-vpio-and-process-tap-do-coexist.md).

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

**ScreenCaptureKit is the default; Process Tap is the second backend.** The default was flipped on a measurement, not a preference: SCK delivers 1.5–2.5× more signal because voice-processing ducking hits the tap harder, and quiet audio is the product's main quality limit ([ADR-0006](docs/adr/0006-screencapturekit-default-for-them.md)). The spec's original case for the tap has mostly expired — both APIs are **app-level**, neither isolates a browser tab, and Screen Recording is needed anyway because every suggestion carries a screenshot. What survives is that the tap sees *any* process making sound, while SCK lists only windowed applications; that is why it stays.

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

Cancellation there is narrower than it looks, and the boundary is load-bearing: a superseded turn loses its *answer* — the stream, the screenshot being taken for it, the right to start a suggestion at all — and keeps its *words*. Speech recognition is never cancelled, because the interlocutor who paused mid-sentence left two turns behind and the new request is composed from both; cancel it and the prompt gets an empty `Them` turn instead of the first half of the question. What stops the stale branch is `SessionEngine.answering`, not `Task.cancel()`.

The manual modes (`Ask`, `Solve on screen`) are the same loop entered from the other end and obey the same rules — `SessionEngine.ask(_:)` and `solveOnScreen()` supersede first, then capture, then stream. They are not a side channel: the next `Them` turn cancels a manual answer exactly as it cancels an automatic one, and a manual request clears `answering` so that the two never generate into the feed side by side.

The planned Swift file layout (`App/`, `UI/`, `Audio/`, `Speech/`, `Intelligence/{Context,LLM,Screen}/`, `Input/`, `Settings/`, `Utilities/`) is in [docs/GhostMeet.md](docs/GhostMeet.md) — follow it when creating files rather than inventing a new structure.

## Modes and prompts

Six user-facing modes — Assist, What should I say?, Follow-up, Recap, Ask, Solve on screen — plus a background Summarizer. **The authoritative prompt texts live in [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md); read it before touching prompt-building code, and update it in the same change if a prompt shifts.**

Cross-cutting rules from that file that are easy to get wrong:

- Never crash or bail on an empty transcript — substitute a placeholder like `(пусто)` and still answer, or, where the document's template guards the block with `{{#if transcript}}`, omit it entirely. Never send a bare heading: that reads to the model as "nothing was said", which is a different and usually wrong claim
- Don't force Russian: response language follows the language of the Them/You turns or the user's question
- Different modes read different transcript window sizes (12 / 14 / 20 / all / none at all for Solve) and different max-token budgets (256–512 for Say/Follow-up, 2k–4k for Ask/Solve/Assist)
- Multimodal modes (Assist, Ask, Solve on screen) attach the screenshot to the *user* message; all three also pass the Vision-framework OCR text, which is the only thing a text-only provider ever learns about the screen
- The optional `resume_context` block at the end of that file is **not optional here** — it carries the user's `Профиль` and ships in the MVP. Without it the model suggests experience the user doesn't have, which is a worse failure than a slow answer. The one exception is `Solve on screen`, whose answer goes into an editor rather than into a sentence said out loud — see note 5 of the prompt document

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
