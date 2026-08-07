# 01 — VPIO выключен везде

**What to build:** `MicCaptureService` больше не вызывает `setVoiceProcessingEnabled(true)` ни в одной конфигурации.

Причина и все измерения — в [ADR-0009](../../../docs/adr/0009-no-vpio-echo-is-ours-to-handle.md). Коротко: включение VPIO отнимает у всех прочих потребителей встроенного микрофона 28–32 дБ, включая браузер, в котором идёт звонок.

**Blocked by:** None.

**Status:** ready-for-agent

- [ ] VPIO не включается ни при каких настройках и ни при каком бэкенде канала `Them`
- [ ] `SettingsStore.allowsVoiceProcessing` удалён, а не переведён в `false`: точка расширения себя исчерпала
- [ ] Ветка отказа `CaptureError.voiceProcessingUnavailable` удалена вместе с её текстом — включать нечего, отказывать не в чем
- [ ] `voiceProcessingOtherAudioDuckingConfiguration` удалён: он имел смысл только при включённом VPIO
- [ ] `MicCaptureService.firstChannel` **остаётся** и остаётся покрытым тестами: гарнитуры отдают два канала, и правило «не просить конвертер свести больше двух» в силе
- [ ] Тап по-прежнему ставится с `format: nil` — причина та же и никуда не делась
- [ ] Комментарии, ссылающиеся на ADR-0005 и ADR-0007 в старом смысле, переписаны: в `MicCaptureService.swift`, `SettingsStore.swift`, `SessionController.swift`
- [ ] Тесты: захват стартует без VPIO; отсутствующая настройка нигде не читается; регрессия `firstChannel` цела

## Что решить по ходу

**Что делать с `MicCaptureService(voiceProcessing:)`.** Параметр либо исчезает совсем, либо остаётся ради тестов. Оставлять флаг, который всегда `false`, — это ровно то, от чего предостерегает тикет 03 прошлой поставки. Решить и записать.
