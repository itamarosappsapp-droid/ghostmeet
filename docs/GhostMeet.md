# GhostMeet Assistant

macOS-приложение для real-time помощи во время видеозвонков (Google Meet, Яндекс Телемост, Zoom, Teams и т.д.).

Приложение:
- Слушает **два канала**: твой микрофон (**You**) и звук собеседников (**Them**)
- Распознаёт речь локально (Whisper MLX)
- Мгновенно отвечает через подключаемые LLM (облачные + локальные)
- Может анализировать экран и давать готовые решения задач
- Отображается поверх всех окон
- Скрывается при шаринге экрана (пользователь шарит вкладку/окно; окно приложения помечено как private)
- Поддерживает прозрачность, изменение размера и горячие клавиши

---

## Основные возможности

### Аудио — dual-channel (You / Them)

По образцу [cue](https://github.com/Blueturboguy07/cue) и [Scripta](https://github.com/thehwang/Scripta) / [CallCapture](https://github.com/bodharma/callcapture) / [Muesli](https://github.com/Muesli-HQ/muesli):

| Канал | Источник | Как захватываем |
|--------|----------|-----------------|
| **You** | Твой микрофон | AVAudioEngine / AVCaptureSession |
| **Them** | Исходящий звук звонилки | **Core Audio Process Tap** на процесс Chrome / Telemost / Zoom / Teams |

Потоки **никогда не смешиваются**. Каждый идёт в свой буфер → свой STT → в transcript с меткой канала:

```text
Them: Какую базу вы используете?
You: PostgreSQL и Redis
Them: А почему не Mongo?
```

Модель видит размеченный диалог и по system prompt понимает, за кого отвечать.

**Почему Process Tap, а не getDisplayMedia loopback (как в cue):**
- Чище: только выбранный процесс, без уведомлений и музыки
- Меньше риска, что твой голос попадёт в Them (нет loopback monitoring)
- Узкое permission (Audio Capture), а не обязательно Screen Recording  
  Reference: [CallCapture](https://github.com/bodharma/callcapture), [Recap](https://github.com/RecapAI/Recap), [AudioCap](https://github.com/insidegui/AudioCap), [audiotee](https://github.com/makeusabrew/audiotee)

Fallback (опционально): ScreenCaptureKit system audio, если Process Tap недоступен.

### Speech-to-Text
- Основной: **Whisper через MLX** (локально, Apple Silicon)
- Fallback: Apple Speech Framework
- Отдельный flush для каждого канала (как в cue: ~3–4 сек + RMS-gate против тишины)
- Модели: `tiny` / `base` / `small` / `medium` (выбор по железу)

### LLM (подключаемые провайдеры)

Единый протокол (идея как в cue `src/llm.js`, но расширенная):

| Тип | Провайдеры |
|-----|----------|
| Облачные | Anthropic Claude, OpenAI, Moonshot Kimi, Gemini, DeepSeek, Grok… |
| Локальные | Ollama, LM Studio, llama.cpp server, MLX-LM |
| CLI | Любой CLI, который принимает текст и пишет ответ в stdout |

Настройки на провайдера: API key / base URL, модель, system prompt, temperature, streaming.

### Контекст разговора
- Скользящее окно последних N минут / N реплик (по умолчанию ~10–15 реплик, как limit в cue prompts)
- Старое автоматически суммаризируется и подмешивается в system prompt
- Можно очистить одной кнопкой / хоткеем

### Анализ экрана
- Хоткей → скриншот (ScreenCaptureKit / CGWindow)
- OCR через Vision Framework
- Режим «Реши задачу» — готовый ответ, не лекция  
  Промпт-подход близок к режиму `leetcode` / `assist` в [cue](https://github.com/Blueturboguy07/cue)

### Интерфейс
- Always-on-top (`NSWindow` level + `collectionBehavior`)
- `sharingType = .none` / content protection — исключение из screen capture  
  (та же идея, что `setContentProtection(true)` в cue)
- Регулируемая прозрачность, ресайз, сохранение позиции
- Компактный / расширенный режим
- Индикаторы: слушает / думает / ошибка; live-dot для dual-channel

### Горячие клавиши (настраиваемые)
- Показать / скрыть
- Assist («что сделать / что сказать сейчас»)
- Скриншот → решить задачу
- Старт/стоп listening
- Очистить контекст
- Прозрачность

### Скрытие при шаринге
Пользователь шарит **вкладку или окно**, не весь экран.  
Окно GhostMeet с `sharingType = .none` не попадает в захват.  
Для Zoom (как в cue): Screen capture mode → *Advanced capture with window filtering*.

---

## Архитектура

```
┌──────────────────────────────────────────────────────────────┐
│                         GhostMeet                            │
├─────────────────┬──────────────────────┬─────────────────────┤
│   UI (SwiftUI)  │   Audio Pipeline     │  Intelligence       │
│                 │                      │                     │
│ Always-on-top   │  Mic ──► You buffer  │  STT (Whisper MLX)  │
│ Opacity/Resize  │  ProcessTap ─► Them  │         ↓           │
│ Hotkeys         │         ↓            │  Transcript You/Them│
│                 │  PCM queues          │         ↓           │
│                 │                      │  Context + Summary  │
│                 │                      │         ↓           │
│                 │                      │  LLM Router         │
│                 │                      │  (Claude/Kimi/…)    │
└─────────────────┴──────────────────────┴─────────────────────┘
```

### Dual-channel пайплайн (по мотивам cue)

1. **Capture**  
   - You: AVAudioEngine  
   - Them: Core Audio Process Tap → Aggregate Device → IOProc  

2. **Buffer + gate**  
   Отдельные буферы `you` / `them`.  
   Flush каждые ~3–4 с, минимум длины (~0.5–0.8 с), RMS-gate от тишины  
   (как `FLUSH_MS` / `MIN_BYTES` / `RMS_GATE` в [cue/main.js](https://github.com/Blueturboguy07/cue/blob/main/main.js)).

3. **STT**  
   Локальный Whisper MLX на каждый канал независимо.

4. **Transcript**  
   ```swift
   struct Turn {
     var channel: Channel // .you / .them
     var text: String
     var timestamp: Date
   }
   ```

5. **LLM**  
   Промпт собирает размеченный диалог + опциональный скриншот.

---

## Режимы (промпты)

Вдохновлено [cue/src/prompts.js](https://github.com/Blueturboguy07/cue/blob/main/src/prompts.js).  
Полные тексты system/user промптов — в файле `GhostMeet-Prompts.md`.

| Режим | Назначение | Входы |
|-------|------------|--------|
| **Assist** | Сделай умное действие прямо сейчас | экран + последние реплики |
| **What should I say?** | Одна короткая реплика от первого лица | transcript You/Them |
| **Follow-up** | 2–4 уточняющих вопроса | transcript |
| **Recap** | Краткое саммари | весь / сжатый контекст |
| **Ask** | Свободный вопрос пользователя | экран + transcript |
| **Solve on screen** | Готовое решение задачи с экрана | скриншот (+ OCR) |

---

## Технический стек

| Компонент | Технология | Reference |
|-----------|------------|-----------|
| UI | SwiftUI + AppKit | — |
| Always-on-top + hide | `NSWindow` level, `sharingType = .none` | [cue](https://github.com/Blueturboguy07/cue) (`setContentProtection`) |
| Them audio | Core Audio Process Tap | [CallCapture](https://github.com/bodharma/callcapture), [Recap](https://github.com/RecapAI/Recap), [AudioCap](https://github.com/insidegui/AudioCap), [Muesli](https://github.com/Muesli-HQ/muesli) |
| You audio | AVAudioEngine | Scripta, Muesli, стандарт Apple |
| STT | Whisper MLX (local) | mlx-swift / mlx-swift-audio ecosystem |
| OCR | Vision Framework | — |
| LLM | Протокол + URLSession / local HTTP / CLI | идея фабрики как в [cue/src/llm.js](https://github.com/Blueturboguy07/cue/blob/main/src/llm.js) |
| Min OS | macOS 14.4+ (Process Tap) | — |

---

## Структура проекта (нативный Swift)

```
GhostMeet/
├── App/
│   ├── GhostMeetApp.swift
│   └── AppState.swift
├── UI/
│   ├── MainWindow/          # always-on-top, opacity, resize
│   ├── Settings/
│   └── Components/
├── Audio/
│   ├── ProcessTapManager.swift    # Them (Core Audio Tap)
│   ├── MicCaptureService.swift    # You
│   ├── AudioCaptureService.swift  # оркестрация dual-channel
│   ├── ProcessListService.swift
│   └── AudioBufferQueue.swift     # отдельные очереди you/them
├── Speech/
│   ├── SpeechRecognitionService.swift
│   ├── WhisperMLXRecognizer.swift
│   └── PartialResult.swift
├── Intelligence/
│   ├── Context/
│   │   ├── ConversationContext.swift  # Turns You/Them + summary
│   │   └── Summarizer.swift
│   ├── LLM/
│   │   ├── LLMProvider.swift
│   │   ├── LLMRouter.swift
│   │   └── Providers/ ...
│   └── Screen/
│       ├── ScreenCaptureService.swift
│       ├── OCRService.swift
│       └── TaskSolver.swift
├── Input/
│   └── HotkeyManager.swift
├── Settings/
│   └── SettingsStore.swift
└── Utilities/
    ├── PermissionsManager.swift
    └── KeychainHelper.swift
```

---

## Разрешения (Info.plist)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Нужен доступ к микрофону, чтобы учитывать ваши реплики в контексте (канал You)</string>

<key>NSAudioCaptureUsageDescription</key>
<string>Нужен доступ к системному аудио, чтобы распознавать речь собеседников (канал Them)</string>

<key>NSScreenCaptureUsageDescription</key>
<string>Нужен для анализа экрана и режима «Реши задачу»</string>
```

---

## Практики, которые берём из существующих проектов

| Практика | Откуда | Как применяем |
|----------|--------|----------------|
| Dual-channel You/Them + размеченный transcript | [cue](https://github.com/Blueturboguy07/cue) | Два буфера, метки в промпте |
| Flush по таймеру + RMS silence gate | [cue/main.js](https://github.com/Blueturboguy07/cue/blob/main/main.js) | Меньше мусорных STT-вызовов |
| Режимы Assist / Say / Follow-up / Recap / Solve | [cue/src/prompts.js](https://github.com/Blueturboguy07/cue/blob/main/src/prompts.js) | Готовые сценарии UX |
| `setContentProtection` / `sharingType = .none` | [cue](https://github.com/Blueturboguy07/cue), research window privacy | Скрытие от screen share |
| Core Audio Process Tap для system/app audio | [CallCapture](https://github.com/bodharma/callcapture), [Recap](https://github.com/RecapAI/Recap), [AudioCap](https://github.com/insidegui/AudioCap), [Muesli](https://github.com/Muesli-HQ/muesli) | Чистый канал Them |
| Локальный STT + опциональный local LLM | [Scripta](https://github.com/thehwang/Scripta), [Recap](https://github.com/RecapAI/Recap) | Приватность по умолчанию |
| BYOK, без своего сервера | [cue](https://github.com/Blueturboguy07/cue) | Ключи только локально (Keychain) |

---

## Отличия GhostMeet от cue

| | cue | GhostMeet |
|--|-----|-----------|
| Стек | Electron | Native Swift |
| Them audio | getDisplayMedia loopback | Core Audio Process Tap |
| STT | Облачный Whisper / Gemini | Локальный Whisper MLX |
| LLM | OpenAI / Claude / Gemini | + Ollama, LM Studio, llama.cpp, CLI, Kimi… |
| Контекст | Последние N реплик | N реплик + авто-саммари |
| UI настройки | Базовые | Прозрачность, размер, профили |

---

## MVP → v1

### MVP
- [ ] Dual-channel: Mic (You) + Process Tap (Them)
- [ ] Whisper MLX (базовый flush + RMS gate)
- [ ] Transcript You/Them
- [ ] Один облачный LLM (Claude или OpenAI) + streaming
- [ ] Режимы Assist + What should I say + Solve on screen
- [ ] Always-on-top + sharingType = .none
- [ ] Базовые хоткеи

### v1.0
- [ ] Полный LLM router (Ollama, LM Studio, llama.cpp, CLI, Kimi…)
- [ ] Контекст с саммаризацией
- [ ] Прозрачность / ресайз / профили промптов
- [ ] OCR + multimodal «Реши задачу»
- [ ] Выбор процесса для тапа в UI

---

## Принципы

1. **Два чистых канала** — модель всегда знает, кто говорил.
2. **Минимальная задержка** — streaming на STT (по возможности) и на LLM.
3. **Приватность** — STT локальный; LLM может быть полностью локальным.
4. **Невидимость** — не мешать и не светиться в screen share.
5. **Гибкость провайдеров** — любой бэкенд через один интерфейс.

---

*Документ — рабочая спецификация. Практики и ссылки актуализированы по открытым репозиториям: cue, CallCapture, Recap, Scripta, Muesli, AudioCap.*

*Промпты режимов: см. `GhostMeet-Prompts.md`.*
